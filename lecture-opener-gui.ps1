Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

$script:Root = $PSScriptRoot
if (-not $script:Root) { $script:Root = Split-Path -Parent $MyInvocation.MyCommand.Path }
$script:DataPath = Join-Path $script:Root "data.json"
$script:ConfigPath = Join-Path $script:Root "config.json"
$script:LogFile = Join-Path $script:Root "log.txt"
$script:RunnerPath = Join-Path $script:Root "lecture-opener.ps1"
$script:LoginProfilePath = Join-Path $script:Root "login-profile.ps1"

$script:dayMap = [ordered]@{
    'Sunday' = 'Sunday'; 'Monday' = 'Monday'; 'Tuesday' = 'Tuesday'
    'Wednesday' = 'Wednesday'; 'Thursday' = 'Thursday'; 'Friday' = 'Friday'; 'Saturday' = 'Saturday'
}
$script:modeMap = [ordered]@{ 'link' = 'Direct Link'; 'classroom' = 'Google Classroom' }

function ConvertTo-DisplayDay { param([string]$en) if ($script:dayMap.Contains($en)) { return $script:dayMap[$en] } return $en }
function ConvertTo-DisplayMode { param([string]$m) if ($script:modeMap.Contains($m)) { return $script:modeMap[$m] } return $m }

$script:data = $null
$script:currentProfileIdx = -1
$script:lastLogSize = 0
$script:runnerProc = $null
$script:timer = $null

function New-LectureObject {
    param($l)
    [pscustomobject]@{
        Name        = [string]$l.name
        Day         = [string]$l.day
        DayDisplay  = ConvertTo-DisplayDay ([string]$l.day)
        Time        = [string]$l.time
        Link        = [string]$l.link
        Mode        = [string]$l.mode
        ModeDisplay = ConvertTo-DisplayMode ([string]$l.mode)
        Advance     = [int]$l.advance
        Delay       = [int]$l.delay
        Classroom   = [string]$l.classroom
    }
}

function New-EmptyProfile {
    param([string]$name)
    [pscustomobject]@{
        name          = $name
        account       = ""
        chromeProfile = "chrome-profile"
        schedule      = (New-Object System.Collections.ArrayList)
    }
}

function Read-AppData {
    $data = [pscustomobject]@{ timezoneId = ''; lastProfile = ''; profiles = (New-Object System.Collections.ArrayList) }
    if (Test-Path -LiteralPath $script:DataPath) {
        try {
            $obj = Get-Content -LiteralPath $script:DataPath -Raw | ConvertFrom-Json
            $data.timezoneId = [string]$obj.timezoneId
            $data.lastProfile = [string]$obj.lastProfile
            foreach ($p in @($obj.profiles)) {
                $profile = [pscustomobject]@{
                    name          = [string]$p.name
                    account       = [string]$p.account
                    chromeProfile = [string]$p.chromeProfile
                    schedule      = (New-Object System.Collections.ArrayList)
                }
                foreach ($l in @($p.schedule)) {
                    [void]$profile.schedule.Add((New-LectureObject $l))
                }
                [void]$data.profiles.Add($profile)
            }
        } catch {
            $data = [pscustomobject]@{ timezoneId = ''; lastProfile = ''; profiles = (New-Object System.Collections.ArrayList) }
        }
    }
    if ($data.profiles.Count -eq 0) {
        [void]$data.profiles.Add((New-EmptyProfile "My University"))
    }
    return $data
}

function Save-AppData {
    $outProfiles = @()
    foreach ($p in $script:data.profiles) {
        $outSchedule = @()
        foreach ($l in $p.schedule) {
            $outSchedule += [ordered]@{
                name      = $l.Name
                link      = $l.Link
                day       = $l.Day
                time      = $l.Time
                advance   = [int]$l.Advance
                delay     = [int]$l.Delay
                mode      = $l.Mode
                classroom = $l.Classroom
            }
        }
        $outProfiles += [ordered]@{ name = $p.name; account = $p.account; chromeProfile = $p.chromeProfile; schedule = $outSchedule }
    }
    $payload = [ordered]@{ timezoneId = $script:data.timezoneId; lastProfile = $script:data.lastProfile; profiles = $outProfiles }
    $payload | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $script:DataPath -Encoding UTF8
    @{ lastProfile = $script:data.lastProfile; timezoneId = $script:data.timezoneId } | ConvertTo-Json | Set-Content -LiteralPath $script:ConfigPath -Encoding UTF8
}

function Get-ChromePath {
    $paths = @(
        "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
        "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
        "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe"
    )
    foreach ($p in $paths) { if (Test-Path -LiteralPath $p) { return $p } }
    return $null
}

function Get-LectureOpenTime {
    param($now, [System.DayOfWeek]$dow, [string]$timeStr, $advance, $delay)
    $d = $now.Date
    while ($d.DayOfWeek -ne $dow) { $d = $d.AddDays(1) }
    $t = $null
    try {
        $t = [datetime]::ParseExact([string]$timeStr, [string[]]@('HH:mm', 'H:mm'), [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None)
    } catch { $t = $null }
    if (-not $t) { return $null }
    $open = $d.AddHours($t.Hour).AddMinutes($t.Minute).AddMinutes([int]$delay - [int]$advance)
    if ($open -le $now) { $open = $open.AddDays(7) }
    return $open
}

function Get-NextLecture {
    $tz = $null
    if ($script:data.timezoneId) { try { $tz = [System.TimeZoneInfo]::FindSystemTimeZoneById($script:data.timezoneId) } catch {} }
    if (-not $tz) { $tz = [System.TimeZoneInfo]::Local }
    $now = [System.TimeZoneInfo]::ConvertTime([DateTime]::UtcNow, $tz)
    $best = $null
    foreach ($p in $script:data.profiles) {
        foreach ($l in $p.schedule) {
            $dow = $null
            try { $dow = [System.Enum]::Parse('System.DayOfWeek', $l.Day) } catch { continue }
            $open = Get-LectureOpenTime $now $dow $l.Time $l.Advance $l.Delay
            if ($open -gt $now -and (-not $best -or $open -lt $best.time)) {
                $best = [pscustomobject]@{ profile = $p; lec = $l; time = $open }
            }
        }
    }
    return $best
}

$mainXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Lecture Opener" Height="750" Width="1100" MinHeight="650" MinWidth="900"
        WindowStartupLocation="CenterScreen" FlowDirection="LeftToRight"
        Background="#0F172A" FontFamily="Segoe UI" Foreground="#E2E8F0">

    <Window.Resources>
        <Style x:Key="GlassCard" TargetType="Border">
            <Setter Property="Background" Value="#1E293B"/>
            <Setter Property="BorderBrush" Value="#334155"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="CornerRadius" Value="12"/>
            <Setter Property="Padding" Value="16"/>
        </Style>

        <Style TargetType="Button">
            <Setter Property="Background" Value="#2563EB"/>
            <Setter Property="Foreground" Value="White"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="Padding" Value="16,8"/>
            <Setter Property="Margin" Value="0,0,8,0"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="btnBorder" Background="{TemplateBinding Background}" CornerRadius="6" Padding="{TemplateBinding Padding}">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="btnBorder" Property="Opacity" Value="0.85"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="btnBorder" Property="Opacity" Value="0.7"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style TargetType="TabItem">
            <Setter Property="Foreground" Value="#94A3B8"/>
            <Setter Property="FontSize" Value="14"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="Padding" Value="16,10"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="TabItem">
                        <Border Name="Border" Background="Transparent" CornerRadius="8,8,0,0" Padding="{TemplateBinding Padding}" Margin="0,0,4,0">
                            <ContentPresenter ContentSource="Header"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsSelected" Value="True">
                                <Setter TargetName="Border" Property="Background" Value="#1E293B"/>
                                <Setter Property="Foreground" Value="#38BDF8"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style TargetType="DataGrid">
            <Setter Property="Background" Value="#1E293B"/>
            <Setter Property="RowBackground" Value="#1E293B"/>
            <Setter Property="AlternatingRowBackground" Value="#0F172A"/>
            <Setter Property="Foreground" Value="#F8FAFC"/>
            <Setter Property="HorizontalGridLinesBrush" Value="#334155"/>
            <Setter Property="VerticalGridLinesBrush" Value="Transparent"/>
            <Setter Property="BorderBrush" Value="#334155"/>
            <Setter Property="BorderThickness" Value="1"/>
        </Style>
        <Style TargetType="DataGridColumnHeader">
            <Setter Property="Background" Value="#0F172A"/>
            <Setter Property="Foreground" Value="#94A3B8"/>
            <Setter Property="FontWeight" Value="Bold"/>
            <Setter Property="Padding" Value="8,10"/>
            <Setter Property="BorderThickness" Value="0,0,0,1"/>
            <Setter Property="BorderBrush" Value="#334155"/>
        </Style>
    </Window.Resources>

    <Grid>
        <DockPanel>
            <Border DockPanel.Dock="Top" Background="#0B0F19" Padding="20,16" BorderBrush="#1E293B" BorderThickness="0,0,0,1">
                <Grid>
                    <StackPanel Orientation="Vertical">
                        <TextBlock Text="Lecture Opener" FontSize="22" FontWeight="Bold" Foreground="#F8FAFC"/>
                        <TextBlock Text="Opens your lectures on time automatically" FontSize="12" Foreground="#64748B" Margin="0,2,0,0"/>
                    </StackPanel>
                    
                    <Border HorizontalAlignment="Right" Background="#1E293B" CornerRadius="20" Padding="12,6" BorderBrush="#334155" BorderThickness="1">
                        <StackPanel Orientation="Horizontal">
                            <Ellipse Width="10" Height="10" Fill="#10B981" Margin="0,0,8,0"/>
                            <TextBlock Name="HeaderProfileText" Text="My University" Foreground="#E2E8F0" FontWeight="SemiBold" FontSize="12" VerticalAlignment="Center"/>
                        </StackPanel>
                    </Border>
                </Grid>
            </Border>

            <StatusBar DockPanel.Dock="Bottom" Background="#0B0F19" Foreground="#64748B" BorderBrush="#1E293B" BorderThickness="0,1,0,0">
                <StatusBarItem>
                    <TextBlock Name="StatusHintText" Text="Ready" Foreground="#94A3B8"/>
                </StatusBarItem>
            </StatusBar>

            <TabControl Background="Transparent" BorderThickness="0" Margin="16">
                
                <TabItem Header="Dashboard">
                    <Grid Margin="0,12,0,0">
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="*"/>
                            <ColumnDefinition Width="300"/>
                        </Grid.ColumnDefinitions>

                        <StackPanel Grid.Column="0" Margin="0,0,16,0">
                            <Border Style="{StaticResource GlassCard}" Margin="0,0,0,16">
                                <Grid>
                                    <Grid.ColumnDefinitions>
                                        <ColumnDefinition Width="*"/>
                                        <ColumnDefinition Width="Auto"/>
                                    </Grid.ColumnDefinitions>
                                    <StackPanel VerticalAlignment="Center">
                                        <StackPanel Orientation="Horizontal" Margin="0,0,0,6">
                                            <TextBlock Text="Status: " FontSize="16" Foreground="#94A3B8"/>
                                            <TextBlock Name="RunStateText" FontSize="16" FontWeight="Bold" Text="Stopped" Foreground="#EF4444"/>
                                        </StackPanel>
                                        <TextBlock Name="NextLectureText" FontSize="13" Foreground="#CBD5E1" TextWrapping="Wrap"/>
                                    </StackPanel>

                                    <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
                                        <Button Name="StartBtn" Content="▶ Start" Background="#10B981"/>
                                        <Button Name="RestartBtn" Content="↻ Reload" Background="#F59E0B"/>
                                        <Button Name="StopBtn" Content="■ Stop" Background="#EF4444"/>
                                    </StackPanel>
                                </Grid>
                            </Border>

                            <Border Style="{StaticResource GlassCard}">
                                <DockPanel Height="380">
                                    <DockPanel DockPanel.Dock="Top" Margin="0,0,0,10">
                                        <Button Name="ClearLogBtn" DockPanel.Dock="Right" Content="Clear Log" Height="26" Padding="10,0" Background="#EF4444" VerticalAlignment="Center"/>
                                        <TextBlock Text="Application Log" FontSize="14" FontWeight="Bold" Foreground="#38BDF8" VerticalAlignment="Center"/>
                                    </DockPanel>
                                    <TextBox Name="LogBox" IsReadOnly="True" AcceptsReturn="True" VerticalScrollBarVisibility="Auto"
                                             Background="#0F172A" Foreground="#34D399" BorderBrush="#334155" Padding="10"
                                             FontFamily="Consolas" FontSize="12"/>
                                </DockPanel>
                            </Border>
                        </StackPanel>

                        <Border Grid.Column="1" Style="{StaticResource GlassCard}" VerticalAlignment="Top">
                            <StackPanel>
                                <TextBlock Text="Profile Context" FontSize="14" FontWeight="Bold" Foreground="#38BDF8" Margin="0,0,0,12"/>
                                <Border Background="#0F172A" CornerRadius="8" Padding="12" BorderBrush="#334155" BorderThickness="1">
                                    <StackPanel>
                                        <TextBlock Text="Active Profile:" FontSize="11" Foreground="#64748B"/>
                                        <ComboBox Name="ActiveProfileCombo" Height="32" Margin="0,6,0,0" Background="#1E293B" Foreground="Black"/>
                                    </StackPanel>
                                </Border>
                            </StackPanel>
                        </Border>
                    </Grid>
                </TabItem>

                <TabItem Header="Lectures">
                    <Grid Margin="0,12,0,0">
                        <Grid.RowDefinitions>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="*"/>
                        </Grid.RowDefinitions>

                        <Border Grid.Row="0" Style="{StaticResource GlassCard}" Margin="0,0,0,12" Padding="10">
                            <DockPanel>
                                <StackPanel DockPanel.Dock="Left" Orientation="Horizontal">
                                    <TextBlock Text="Profile: " VerticalAlignment="Center" Foreground="#94A3B8"/>
                                    <ComboBox Name="ProfileCombo" Width="200" Height="30" Margin="8,0,16,0" Foreground="Black"/>
                                </StackPanel>
                                <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
                                    <Button Name="AddLectureBtn" Content="+ Add Lecture" Background="#10B981"/>
                                    <Button Name="EditLectureBtn" Content="Edit" Background="#3B82F6"/>
                                    <Button Name="DeleteLectureBtn" Content="Delete" Background="#EF4444"/>
                                    <Button Name="OpenClassroomBtn" Content="Google Classroom" Background="#059669"/>
                                </StackPanel>
                            </DockPanel>
                        </Border>

                        <DataGrid Grid.Row="1" Name="LecturesGrid" AutoGenerateColumns="False" IsReadOnly="True"
                                  SelectionMode="Single" HeadersVisibility="Column" RowHeight="36">
                            <DataGrid.Columns>
                                <DataGridTextColumn Header="Subject" Binding="{Binding Name}" Width="160"/>
                                <DataGridTextColumn Header="Day" Binding="{Binding DayDisplay}" Width="100"/>
                                <DataGridTextColumn Header="Time" Binding="{Binding Time}" Width="80"/>
                                <DataGridTextColumn Header="Type" Binding="{Binding ModeDisplay}" Width="120"/>
                                <DataGridTextColumn Header="Advance (m)" Binding="{Binding Advance}" Width="90"/>
                                <DataGridTextColumn Header="Delay (m)" Binding="{Binding Delay}" Width="80"/>
                                <DataGridTextColumn Header="Link" Binding="{Binding Link}" Width="*"/>
                            </DataGrid.Columns>
                        </DataGrid>
                    </Grid>
                </TabItem>

                <TabItem Header="Settings">
                    <Border Style="{StaticResource GlassCard}" Margin="0,12,0,0" HorizontalAlignment="Left" Width="600" VerticalAlignment="Top">
                        <StackPanel>
                            <TextBlock Text="General Settings" FontSize="16" FontWeight="Bold" Foreground="#38BDF8" Margin="0,0,0,16"/>
                            
                            <TextBlock Text="Time Zone (Country / City)" Foreground="#94A3B8" Margin="0,0,0,4"/>
                            <ComboBox Name="TimezoneCombo" Height="32" Margin="0,0,0,4" Foreground="Black"/>
                            <TextBlock Name="TimezoneHint" FontSize="11" Foreground="#64748B" TextWrapping="Wrap" Margin="0,0,0,16"/>

                            <TextBlock Text="Chrome Path" Foreground="#94A3B8" Margin="0,0,0,4"/>
                            <TextBox Name="ChromePathBox" Height="32" IsReadOnly="True" Background="#0F172A" Foreground="#E2E8F0" BorderBrush="#334155" Padding="6" Margin="0,0,0,16"/>

                            <TextBlock Text="Data File Path" Foreground="#94A3B8" Margin="0,0,0,4"/>
                            <TextBox Name="DataPathBox" Height="32" IsReadOnly="True" Background="#0F172A" Foreground="#E2E8F0" BorderBrush="#334155" Padding="6" Margin="0,0,0,24"/>

                            <Button Name="SaveSettingsBtn" Content="Save Settings" HorizontalAlignment="Right" Background="#10B981"/>
                        </StackPanel>
                    </Border>
                </TabItem>
            </TabControl>
        </DockPanel>

        <Border Name="ToastCard" Background="#10B981" CornerRadius="8" Padding="16,10"
                HorizontalAlignment="Center" VerticalAlignment="Bottom" Margin="0,0,0,40"
                Opacity="0" IsHitTestVisible="False" Panel.ZIndex="999">
            <StackPanel Orientation="Horizontal">
                <TextBlock Text="✓ " Foreground="White" FontWeight="Bold" FontSize="14"/>
                <TextBlock Name="ToastText" Text="Notification message" Foreground="White" FontWeight="SemiBold" FontSize="13"/>
            </StackPanel>
        </Border>
    </Grid>
</Window>
'@

$lectureDialogXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Lecture" Width="420" SizeToContent="Height" ResizeMode="NoResize"
        WindowStartupLocation="CenterOwner" FlowDirection="LeftToRight" Background="#1E293B" Foreground="#E2E8F0" FontFamily="Segoe UI">
    <StackPanel Margin="18">
        <TextBlock Text="Lecture Name *"/>
        <TextBox Name="DlgName" Height="28" Margin="0,4,0,10" Background="#0F172A" Foreground="White" Padding="4"/>
        <TextBlock Text="Day *"/>
        <ComboBox Name="DlgDay" Height="28" Margin="0,4,0,10" Foreground="Black"/>
        <TextBlock Text="Time (24H) e.g. 08:00 *"/>
        <TextBox Name="DlgTime" Height="28" Margin="0,4,0,10" Background="#0F172A" Foreground="White" Padding="4"/>
        <TextBlock Text="Opening Mode"/>
        <ComboBox Name="DlgMode" Height="28" Margin="0,4,0,10" Foreground="Black"/>
        <StackPanel Name="DlgClassroomPanel">
            <TextBlock Text="Classroom Name (exact as shown in Google Classroom) *"/>
            <TextBox Name="DlgClassroom" Height="28" Margin="0,4,0,10" Background="#0F172A" Foreground="White" Padding="4"/>
        </StackPanel>
        <TextBlock Text="Meeting Link"/>
        <TextBox Name="DlgLink" Height="28" Margin="0,4,0,10" Background="#0F172A" Foreground="White" Padding="4"/>
        <TextBlock Text="Advance Opening (Minutes)"/>
        <TextBox Name="DlgAdvance" Height="28" Margin="0,4,0,10" Background="#0F172A" Foreground="White" Padding="4"/>
        <TextBlock Text="Delay Opening (Minutes)"/>
        <TextBox Name="DlgDelay" Height="28" Margin="0,4,0,16" Background="#0F172A" Foreground="White" Padding="4"/>
        <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
            <Button Name="DlgOk" Content="Save" Width="90" Height="32" IsDefault="True" Background="#10B981"/>
            <Button Name="DlgCancel" Content="Cancel" Width="90" Height="32" Background="#64748B" IsCancel="True"/>
        </StackPanel>
    </StackPanel>
</Window>
'@

function Show-Toast {
    param([string]$message)
    $ToastText.Text = $message
    $anim = New-Object System.Windows.Media.Animation.DoubleAnimationUsingKeyFrames
    
    $kf1 = New-Object System.Windows.Media.Animation.LinearDoubleKeyFrame(0, [System.Windows.Media.Animation.KeyTime]::FromTimeSpan([TimeSpan]::FromMilliseconds(0)))
    $kf2 = New-Object System.Windows.Media.Animation.LinearDoubleKeyFrame(1, [System.Windows.Media.Animation.KeyTime]::FromTimeSpan([TimeSpan]::FromMilliseconds(200)))
    $kf3 = New-Object System.Windows.Media.Animation.LinearDoubleKeyFrame(1, [System.Windows.Media.Animation.KeyTime]::FromTimeSpan([TimeSpan]::FromMilliseconds(1800)))
    $kf4 = New-Object System.Windows.Media.Animation.LinearDoubleKeyFrame(0, [System.Windows.Media.Animation.KeyTime]::FromTimeSpan([TimeSpan]::FromMilliseconds(2200)))
    
    [void]$anim.KeyFrames.Add($kf1)
    [void]$anim.KeyFrames.Add($kf2)
    [void]$anim.KeyFrames.Add($kf3)
    [void]$anim.KeyFrames.Add($kf4)
    
    $ToastCard.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $anim)
}

function Edit-SelectedLecture {
    if ($script:currentProfileIdx -lt 0) { return }
    $sel = $LecturesGrid.SelectedItem
    if (-not $sel) { [void][System.Windows.MessageBox]::Show('Please select a lecture first.', 'Notice', 'OK', 'Information'); return }
    $res = Show-LectureDialog -existing $sel -title 'Edit Lecture'
    if ($res) {
        $sel.Name = $res.Name
        $sel.Day = $res.Day
        $sel.DayDisplay = $res.DayDisplay
        $sel.Time = $res.Time
        $sel.Link = $res.Link
        $sel.Mode = $res.Mode
        $sel.ModeDisplay = $res.ModeDisplay
        $sel.Advance = $res.Advance
        $sel.Delay = $res.Delay
        $sel.Classroom = $res.Classroom
        Save-AppData
        Refresh-LecturesGrid
        Show-Toast "Lecture updated successfully!"
    }
}

function Show-LectureDialog {
    param([object]$existing, [string]$title)
    $xml = [xml]$lectureDialogXaml
    $reader = New-Object System.Xml.XmlNodeReader $xml
    $dlg = [System.Windows.Markup.XamlReader]::Load($reader)
    $dlg.Title = $title
    $dlg.Owner = $script:mainWindow

    $nameBox = $dlg.FindName('DlgName')
    $dayBox = $dlg.FindName('DlgDay')
    $timeBox = $dlg.FindName('DlgTime')
    $modeBox = $dlg.FindName('DlgMode')
    $classroomPanel = $dlg.FindName('DlgClassroomPanel')
    $classroomBox = $dlg.FindName('DlgClassroom')
    $linkBox = $dlg.FindName('DlgLink')
    $advanceBox = $dlg.FindName('DlgAdvance')
    $delayBox = $dlg.FindName('DlgDelay')

    foreach ($k in $script:dayMap.Keys) {
        $item = New-Object System.Windows.Controls.ComboBoxItem
        $item.Content = $script:dayMap[$k]
        $item.Tag = $k
        [void]$dayBox.Items.Add($item)
    }
    $dayBox.SelectedValuePath = 'Tag'
    foreach ($k in $script:modeMap.Keys) {
        $item = New-Object System.Windows.Controls.ComboBoxItem
        $item.Content = $script:modeMap[$k]
        $item.Tag = $k
        [void]$modeBox.Items.Add($item)
    }
    $modeBox.SelectedValuePath = 'Tag'

    if ($existing) {
        $nameBox.Text = $existing.Name
        $timeBox.Text = $existing.Time
        $linkBox.Text = $existing.Link
        $classroomBox.Text = $existing.Classroom
        $advanceBox.Text = "$($existing.Advance)"
        $delayBox.Text = "$($existing.Delay)"
        if ($script:dayMap.Contains($existing.Day)) { $dayBox.SelectedValue = $existing.Day }
        if ($script:modeMap.Contains($existing.Mode)) { $modeBox.SelectedValue = $existing.Mode }
    } else {
        if ($dayBox.Items.Count -gt 0) { $dayBox.SelectedIndex = 0 }
        if ($modeBox.Items.Count -gt 0) { $modeBox.SelectedIndex = 0 }
    }

    function Update-ModeVisibility {
        if ($modeBox.SelectedValue -eq 'classroom') {
            $classroomPanel.Visibility = [System.Windows.Visibility]::Visible
        } else {
            $classroomPanel.Visibility = [System.Windows.Visibility]::Collapsed
        }
    }
    Update-ModeVisibility
    $modeBox.Add_SelectionChanged({ Update-ModeVisibility })

    $ok = $dlg.FindName('DlgOk')
    $ok.Add_Click({
        if ([string]::IsNullOrWhiteSpace($nameBox.Text)) {
            [void][System.Windows.MessageBox]::Show('Please enter lecture name.', 'Warning', 'OK', 'Warning')
            return
        }
        if ($modeBox.SelectedValue -eq 'classroom' -and [string]::IsNullOrWhiteSpace($classroomBox.Text)) {
            [void][System.Windows.MessageBox]::Show('Please enter the Classroom name (as shown in Google Classroom).', 'Warning', 'OK', 'Warning')
            return
        }
        $parsedTime = $null
        $rawTime = $timeBox.Text.Trim()
        try {
            $parsedTime = [datetime]::ParseExact([string]$rawTime, [string[]]@('HH:mm', 'H:mm'), [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None)
        } catch { $parsedTime = $null }
        if (-not $parsedTime) {
            [void][System.Windows.MessageBox]::Show('Please enter a valid time in 24h format (e.g. 08:00 or 4:44).', 'Warning', 'OK', 'Warning')
            return
        }
        $timeBox.Text = $parsedTime.ToString('HH:mm')
        $dlg.DialogResult = $true
    })
    $dlg.FindName('DlgCancel').Add_Click({ $dlg.DialogResult = $false })

    if ($dlg.ShowDialog() -eq $true) {
        $adv = 0; $del = 0
        [int]::TryParse($advanceBox.Text, [ref]$adv) | Out-Null
        [int]::TryParse($delayBox.Text, [ref]$del) | Out-Null
        return [pscustomobject]@{
            Name = $nameBox.Text.Trim(); Day = $dayBox.SelectedValue
            DayDisplay = ConvertTo-DisplayDay $dayBox.SelectedValue
            Time = $timeBox.Text.Trim(); Link = $linkBox.Text.Trim()
            Mode = $modeBox.SelectedValue; ModeDisplay = ConvertTo-DisplayMode $modeBox.SelectedValue
            Advance = $adv; Delay = $del; Classroom = $classroomBox.Text.Trim()
        }
    }
    return $null
}

function Start-Runner {
    if ($script:runnerProc -and -not $script:runnerProc.HasExited) { return }
    Save-AppData
    if (Test-Path -LiteralPath $script:RunnerPath) {
        $runnerArg = '"' + $script:RunnerPath + '"'
        $args = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $runnerArg, '-Auto')
        $script:runnerProc = Start-Process -FilePath 'powershell.exe' -ArgumentList $args -WindowStyle Hidden -PassThru
    } else {
        Add-LogText "[GUI] Warning: Runner script 'lecture-opener.ps1' not found in path."
    }
    Update-RunState
    Show-Toast "Automator Started Successfully!"
}

function Stop-Runner {
    if ($script:runnerProc -and -not $script:runnerProc.HasExited) {
        Stop-Process -Id $script:runnerProc.Id -Force -ErrorAction SilentlyContinue
    }
    $script:runnerProc = $null
    Update-RunState
    Show-Toast "Automator Stopped."
}

function Update-RunState {
    if ($script:runnerProc -and -not $script:runnerProc.HasExited) {
        $RunStateText.Text = 'Running'
        $RunStateText.Foreground = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString('#10B981'))
    } else {
        $RunStateText.Text = 'Stopped'
        $RunStateText.Foreground = [System.Windows.Media.Brushes]::IndianRed
    }
    $next = Get-NextLecture
    if ($next) {
        $NextLectureText.Text = 'Next Lecture: ' + $next.lec.Name + ' (' + $next.lec.Time + ')'
    } else {
        $NextLectureText.Text = 'No upcoming lectures scheduled.'
    }
}

function Add-LogText {
    param([string]$txt)
    if ($LogBox) {
        $LogBox.AppendText("$txt`r`n")
        $LogBox.ScrollToEnd()
    }
}

function Update-LogView {
    if (Test-Path -LiteralPath $script:LogFile) {
        try {
            $file = Get-Item -LiteralPath $script:LogFile
            if ($file.Length -ne $script:lastLogSize) {
                $content = Get-Content -LiteralPath $script:LogFile -Raw -ErrorAction SilentlyContinue
                if ($content) {
                    $LogBox.Text = $content
                    $LogBox.ScrollToEnd()
                }
                $script:lastLogSize = $file.Length
            }
        } catch {}
    }
}

function Refresh-LecturesGrid {
    $LecturesGrid.ItemsSource = $null
    if ($script:currentProfileIdx -ge 0 -and $script:currentProfileIdx -lt $script:data.profiles.Count) {
        $LecturesGrid.ItemsSource = $script:data.profiles[$script:currentProfileIdx].schedule
    }
}

function Refresh-Combos {
    $ProfileCombo.Items.Clear()
    $ActiveProfileCombo.Items.Clear()
    foreach ($p in $script:data.profiles) {
        [void]$ProfileCombo.Items.Add($p.name)
        [void]$ActiveProfileCombo.Items.Add($p.name)
    }
    if ($ProfileCombo.Items.Count -gt 0) { $ProfileCombo.SelectedIndex = 0 }
    if ($ActiveProfileCombo.Items.Count -gt 0) { $ActiveProfileCombo.SelectedIndex = 0 }
}

try {
    $xml = [xml]$mainXaml
    $reader = New-Object System.Xml.XmlNodeReader $xml
    $script:mainWindow = [System.Windows.Markup.XamlReader]::Load($reader)

    $RunStateText = $script:mainWindow.FindName('RunStateText')
    $NextLectureText = $script:mainWindow.FindName('NextLectureText')
    $LogBox = $script:mainWindow.FindName('LogBox')
    $LecturesGrid = $script:mainWindow.FindName('LecturesGrid')
    $ProfileCombo = $script:mainWindow.FindName('ProfileCombo')
    $ActiveProfileCombo = $script:mainWindow.FindName('ActiveProfileCombo')
    $TimezoneCombo = $script:mainWindow.FindName('TimezoneCombo')
    $TimezoneHint = $script:mainWindow.FindName('TimezoneHint')
    $ChromePathBox = $script:mainWindow.FindName('ChromePathBox')
    $DataPathBox = $script:mainWindow.FindName('DataPathBox')
    $ToastCard = $script:mainWindow.FindName('ToastCard')
    $ToastText = $script:mainWindow.FindName('ToastText')

    $script:data = Read-AppData
    Refresh-Combos
    $script:currentProfileIdx = 0
    Refresh-LecturesGrid
    Update-RunState

    $ChromePathBox.Text = Get-ChromePath
    $DataPathBox.Text = $script:DataPath

    $TimezoneCombo.Items.Clear()
    $timezoneList = @([System.TimeZoneInfo]::GetSystemTimeZones() | Sort-Object DisplayName)
    foreach ($tz in $timezoneList) {
        $item = New-Object System.Windows.Controls.ComboBoxItem
        $item.Content = $tz.DisplayName
        $item.Tag = $tz.Id
        [void]$TimezoneCombo.Items.Add($item)
    }
    $TimezoneCombo.SelectedValuePath = 'Tag'
    $savedTz = $null
    if ($script:data.timezoneId) { try { $savedTz = [System.TimeZoneInfo]::FindSystemTimeZoneById($script:data.timezoneId) } catch {} }
    if ($savedTz) {
        $TimezoneCombo.SelectedValue = $savedTz.Id
        $TimezoneHint.Text = "Selected: $($savedTz.Id) ($($savedTz.DisplayName))"
    } else {
        $TimezoneCombo.SelectedValue = [System.TimeZoneInfo]::Local.Id
        $TimezoneHint.Text = "Selected: $([System.TimeZoneInfo]::Local.Id) ($([System.TimeZoneInfo]::Local.DisplayName))"
    }

    # UI Action Bindings
    $script:mainWindow.FindName('StartBtn').Add_Click({ Start-Runner })
    $script:mainWindow.FindName('StopBtn').Add_Click({ Stop-Runner })
    $script:mainWindow.FindName('RestartBtn').Add_Click({ 
        Stop-Runner
        Start-Runner
        Show-Toast "Reloaded Automator Successfully!"
    })
    
    $script:mainWindow.FindName('SaveSettingsBtn').Add_Click({
        $sel = $TimezoneCombo.SelectedItem
        if ($sel -and $sel.Tag) {
            $script:data.timezoneId = [string]$sel.Tag
        } else {
            $script:data.timezoneId = [System.TimeZoneInfo]::Local.Id
        }
        Save-AppData
        $TimezoneHint.Text = "Selected: $($script:data.timezoneId)"
        Show-Toast "Settings saved ($($script:data.timezoneId))"
    })

    $TimezoneCombo.Add_SelectionChanged({
        $sel = $TimezoneCombo.SelectedItem
        if ($sel -and $sel.Tag) {
            $tzId = [string]$sel.Tag
            try {
                $tzObj = [System.TimeZoneInfo]::FindSystemTimeZoneById($tzId)
                $TimezoneHint.Text = "Selected: $($tzObj.Id) ($($tzObj.DisplayName))"
            } catch {
                $TimezoneHint.Text = "Selected: $tzId"
            }
        }
    })

    $script:mainWindow.FindName('ClearLogBtn').Add_Click({
        $LogBox.Clear()
        $script:lastLogSize = 0
        if (Test-Path -LiteralPath $script:LogFile) {
            Set-Content -LiteralPath $script:LogFile -Value "" -Encoding UTF8
        }
    })

    $script:mainWindow.FindName('AddLectureBtn').Add_Click({
        $res = Show-LectureDialog -title 'Add Lecture'
        if ($res) {
            [void]$script:data.profiles[$script:currentProfileIdx].schedule.Add($res)
            Save-AppData
            Refresh-LecturesGrid
            Show-Toast "New lecture added successfully!"
        }
    })
    
    $script:mainWindow.FindName('EditLectureBtn').Add_Click({ Edit-SelectedLecture })
    
    $script:mainWindow.FindName('DeleteLectureBtn').Add_Click({
        $sel = $LecturesGrid.SelectedItem
        if ($sel) {
            [void]$script:data.profiles[$script:currentProfileIdx].schedule.Remove($sel)
            Save-AppData
            Refresh-LecturesGrid
            Show-Toast "Lecture deleted successfully!"
        }
    })

    # Background Live Timer for Status and Logs
    $script:timer = New-Object System.Windows.Threading.DispatcherTimer
    $script:timer.Interval = [TimeSpan]::FromMilliseconds(1000)
    $script:timer.Add_Tick({
        Update-RunState
        Update-LogView
    })
    $script:timer.Start()

    [void]$script:mainWindow.ShowDialog()
} catch {
    [System.Windows.MessageBox]::Show($_.Exception.Message, "Error Starting UI")
}