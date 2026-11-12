[CmdletBinding()]
param([string]$CatalogPath)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $IsWindows) { throw 'The PS Base desktop interface currently requires Windows and PowerShell 7.' }
if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne [Threading.ApartmentState]::STA) {
    throw 'Start PS Base with Start-PSBase.cmd or run pwsh -STA -File ./PS-Base-GUI.ps1.'
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName Microsoft.VisualBasic
[System.Windows.Forms.Application]::EnableVisualStyles()

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:cliPath = Join-Path $root 'PS-Base.ps1'
$script:catalogPath = if ($CatalogPath) { [System.IO.Path]::GetFullPath($CatalogPath) } else { Join-Path $root 'catalog/resources.json' }
Import-Module (Join-Path $root 'src/PSBase/Catalog.psm1') -Force
Import-Module (Join-Path $root 'src/PSBase/DependencyResolver.psm1') -Force
Import-Module (Join-Path $root 'src/PSBase/Auth.psm1') -Force
$script:catalog = Get-PSBaseCatalog -Path $script:catalogPath
$script:busy = $false

$form = [System.Windows.Forms.Form]::new()
$form.Text = 'Pedro Scripts | PS Base'
$form.StartPosition = 'CenterScreen'
$form.Size = [System.Drawing.Size]::new(1050, 760)
$form.MinimumSize = [System.Drawing.Size]::new(900, 650)
$form.Font = [System.Drawing.Font]::new('Segoe UI', 9)
$form.BackColor = [System.Drawing.Color]::FromArgb(246, 247, 249)

$layout = [System.Windows.Forms.TableLayoutPanel]::new()
$layout.Dock = 'Fill'
$layout.Padding = [System.Windows.Forms.Padding]::new(14)
$layout.ColumnCount = 1
$layout.RowCount = 8
foreach ($height in @(44, 38, 38, 34, 100, 44, 100, 32)) {
    $layout.RowStyles.Add([System.Windows.Forms.RowStyle]::new('Absolute', $height))
}
$layout.RowStyles[4].SizeType = 'Percent'
$layout.RowStyles[4].Height = 100
$layout.RowStyles[6].SizeType = 'Absolute'
$layout.RowStyles[6].Height = 100
$form.Controls.Add($layout)

$heading = [System.Windows.Forms.Label]::new()
$heading.Text = 'PEDRO SCRIPTS  /  PS BASE'
$heading.Dock = 'Fill'
$heading.Font = [System.Drawing.Font]::new('Segoe UI Semibold', 17, [System.Drawing.FontStyle]::Bold)
$heading.ForeColor = [System.Drawing.Color]::FromArgb(38, 47, 61)
$heading.TextAlign = 'MiddleLeft'
$layout.Controls.Add($heading, 0, 0)

$serverPanel = [System.Windows.Forms.FlowLayoutPanel]::new()
$serverPanel.Dock = 'Fill'
$serverPanel.WrapContents = $false
$serverPanel.Padding = [System.Windows.Forms.Padding]::new(0, 4, 0, 0)
$layout.Controls.Add($serverPanel, 0, 1)

$serverLabel = [System.Windows.Forms.Label]::new()
$serverLabel.Text = 'RedM server folder'
$serverLabel.Width = 125
$serverLabel.TextAlign = 'MiddleLeft'
$serverPanel.Controls.Add($serverLabel)

$script:serverBox = [System.Windows.Forms.TextBox]::new()
$script:serverBox.Width = 650
$script:serverBox.PlaceholderText = 'Select the folder containing server.cfg and resources'
$serverPanel.Controls.Add($script:serverBox)

$script:browseButton = [System.Windows.Forms.Button]::new()
$script:browseButton.Text = 'Browse...'
$script:browseButton.Width = 100
$serverPanel.Controls.Add($script:browseButton)

$authPanel = [System.Windows.Forms.FlowLayoutPanel]::new()
$authPanel.Dock = 'Fill'
$authPanel.WrapContents = $false
$authPanel.Padding = [System.Windows.Forms.Padding]::new(0, 4, 0, 0)
$layout.Controls.Add($authPanel, 0, 2)

$authLabel = [System.Windows.Forms.Label]::new()
$authLabel.Text = 'GitHub token'
$authLabel.Width = 125
$authLabel.TextAlign = 'MiddleLeft'
$authPanel.Controls.Add($authLabel)

$script:tokenBox = [System.Windows.Forms.TextBox]::new()
$script:tokenBox.Width = 480
$script:tokenBox.UseSystemPasswordChar = $true
$script:tokenBox.PlaceholderText = 'Fine-grained token: read access to the private PS repositories'
$authPanel.Controls.Add($script:tokenBox)

$script:saveToken = [System.Windows.Forms.Button]::new()
$script:saveToken.Text = 'Save securely'
$script:saveToken.Width = 110
$authPanel.Controls.Add($script:saveToken)

$script:clearToken = [System.Windows.Forms.Button]::new()
$script:clearToken.Text = 'Clear'
$script:clearToken.Width = 75
$authPanel.Controls.Add($script:clearToken)

$profilePanel = [System.Windows.Forms.FlowLayoutPanel]::new()
$profilePanel.Dock = 'Fill'
$profilePanel.WrapContents = $false
$layout.Controls.Add($profilePanel, 0, 3)

$profileLabel = [System.Windows.Forms.Label]::new()
$profileLabel.Text = 'Install profile'
$profileLabel.Width = 125
$profileLabel.TextAlign = 'MiddleLeft'
$profilePanel.Controls.Add($profileLabel)

$script:profileBox = [System.Windows.Forms.ComboBox]::new()
$script:profileBox.Width = 250
$script:profileBox.DropDownStyle = 'DropDownList'
$profilePanel.Controls.Add($script:profileBox)

$versionLabel = [System.Windows.Forms.Label]::new()
$versionLabel.Text = 'Version'
$versionLabel.Width = 55
$versionLabel.TextAlign = 'MiddleLeft'
$profilePanel.Controls.Add($versionLabel)

$script:versionBox = [System.Windows.Forms.TextBox]::new()
$script:versionBox.Width = 105
$script:versionBox.PlaceholderText = 'Exact preview version'
$profilePanel.Controls.Add($script:versionBox)

$artifactLabel = [System.Windows.Forms.Label]::new()
$artifactLabel.Text = 'Server artifact'
$artifactLabel.Width = 100
$artifactLabel.TextAlign = 'MiddleLeft'
$profilePanel.Controls.Add($artifactLabel)

$script:artifactBox = [System.Windows.Forms.TextBox]::new()
$script:artifactBox.Width = 120
$script:artifactBox.PlaceholderText = 'Optional'
$profilePanel.Controls.Add($script:artifactBox)

$script:resourceList = [System.Windows.Forms.ListView]::new()
$script:resourceList.Dock = 'Fill'
$script:resourceList.View = 'Details'
$script:resourceList.CheckBoxes = $true
$script:resourceList.FullRowSelect = $true
$script:resourceList.GridLines = $true
$script:resourceList.HideSelection = $false
$script:resourceList.Columns.Add('Resource', 220) | Out-Null
$script:resourceList.Columns.Add('ID', 180) | Out-Null
$script:resourceList.Columns.Add('Status', 110) | Out-Null
$script:resourceList.Columns.Add('Installable', 90) | Out-Null
$script:resourceList.Columns.Add('Releases', 80) | Out-Null
$layout.Controls.Add($script:resourceList, 0, 4)

$footer = [System.Windows.Forms.TableLayoutPanel]::new()
$footer.Dock = 'Fill'
$footer.ColumnCount = 2
$footer.RowCount = 1
$footer.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new('Percent', 100))
$footer.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new('Absolute', 160))
$layout.Controls.Add($footer, 0, 7)

$script:notice = [System.Windows.Forms.Label]::new()
$script:notice.Dock = 'Fill'
$script:notice.TextAlign = 'MiddleLeft'
$script:notice.AutoEllipsis = $true
$footer.Controls.Add($script:notice, 0, 0)

$script:progress = [System.Windows.Forms.ProgressBar]::new()
$script:progress.Dock = 'Fill'
$footer.Controls.Add($script:progress, 1, 0)

$actions = [System.Windows.Forms.FlowLayoutPanel]::new()
$actions.Dock = 'Fill'
$actions.Height = 44
$actions.WrapContents = $false
$actions.Padding = [System.Windows.Forms.Padding]::new(12, 5, 0, 0)
$layout.Controls.Add($actions, 0, 5)

$script:log = [System.Windows.Forms.TextBox]::new()
$script:log.Multiline = $true
$script:log.ReadOnly = $true
$script:log.ScrollBars = 'Vertical'
$script:log.WordWrap = $false
$script:log.Font = [System.Drawing.Font]::new('Consolas', 9)
$script:log.Dock = 'Fill'
$layout.Controls.Add($script:log, 0, 6)

function Add-Log {
    param([string]$Text)
    $script:log.AppendText(('[{0}] {1}{2}' -f [DateTime]::Now.ToString('HH:mm:ss'), $Text, [Environment]::NewLine))
}

function Refresh-Catalog {
    $script:catalog = Get-PSBaseCatalog -Path $script:catalogPath
    $script:resourceList.Items.Clear()
    foreach ($resource in ($script:catalog.resources | Sort-Object name)) {
        $item = [System.Windows.Forms.ListViewItem]::new([string]$resource.name)
        [void]$item.SubItems.Add([string]$resource.id)
        [void]$item.SubItems.Add([string]$resource.status)
        [void]$item.SubItems.Add([string]$resource.installable)
        [void]$item.SubItems.Add([string]@($resource.releases).Count)
        $item.Tag = [string]$resource.id
        $item.Checked = $false
        if (-not $resource.installable) { $item.ForeColor = [System.Drawing.Color]::DimGray }
        [void]$script:resourceList.Items.Add($item)
    }

    $script:profileBox.Items.Clear()
    [void]$script:profileBox.Items.Add([pscustomobject]@{ Name = 'Custom selection'; Id = '' })
    foreach ($profile in @($script:catalog.profiles)) {
        [void]$script:profileBox.Items.Add([pscustomobject]@{ Name = [string]$profile.name; Id = [string]$profile.id })
    }
    $script:profileBox.DisplayMember = 'Name'
    $script:profileBox.SelectedIndex = 0

    $ready = @($script:catalog.resources | Where-Object { $_.installable }).Count
    $script:notice.Text = "$ready of $($script:catalog.resources.Count) resources have published verified releases. Check only the resources you want; dependencies are included automatically."
    if ($ready -eq 0) {
        $script:notice.ForeColor = [System.Drawing.Color]::DarkGoldenrod
        Add-Log 'No installable release assets are in the catalog yet. Release publishing and catalog sync must run first.'
    }
    else {
        $script:notice.ForeColor = [System.Drawing.Color]::DarkGreen
    }
}

function Get-SelectedIds {
    return @($script:resourceList.CheckedItems | ForEach-Object { [string]$_.Tag })
}

function Update-SelectionPreview {
    $ids = @(Get-SelectedIds)
    if ($ids.Count -eq 0) {
        $script:notice.Text = 'Choose the resources you want to install. Required dependencies are added automatically.'
        return
    }

    try {
        $version = $script:versionBox.Text.Trim()
        $plan = if ($version) {
            @(Resolve-PSBaseInstallPlan -Catalog $script:catalog -ResourceIds $ids -Version $version)
        }
        else {
            @(Resolve-PSBaseInstallPlan -Catalog $script:catalog -ResourceIds $ids)
        }
        $dependencies = @($plan | Where-Object { -not $_.Requested } | ForEach-Object { "$($_.Id) $($_.Version)" })
        $selected = @($plan | Where-Object { $_.Requested } | ForEach-Object { $_.Id })
        $script:notice.ForeColor = [System.Drawing.Color]::FromArgb(45, 75, 115)
        if ($dependencies.Count -gt 0) {
            $script:notice.Text = "Selected: $($selected -join ', ') | Automatically included dependencies: $($dependencies -join ', ')"
        }
        else {
            $script:notice.Text = "Selected resources: $($selected -join ', ') | No additional dependencies required."
        }
    }
    catch {
        $script:notice.ForeColor = [System.Drawing.Color]::DarkGoldenrod
        $script:notice.Text = "Selection needs attention: $($_.Exception.Message)"
    }
}

function Get-CommandArgs {
    param([string]$Command, [switch]$NeedsSelection)
    $args = [System.Collections.Generic.List[string]]::new()
    $args.Add('-Command')
    $args.Add($Command)

    $server = $script:serverBox.Text.Trim()
    if ($server) { $args.Add('-ServerPath'); $args.Add($server) }

    $artifact = $script:artifactBox.Text.Trim()
    if ($artifact) { $args.Add('-ArtifactVersion'); $args.Add($artifact) }

    $profile = $script:profileBox.SelectedItem
    $version = $script:versionBox.Text.Trim()
    if ($null -ne $profile -and $profile.Id) {
        if ($version) { throw 'A profile already pins exact versions. Clear the Version field or choose a custom selection.' }
        $args.Add('-Profile')
        $args.Add([string]$profile.Id)
    }
    else {
        $ids = @(Get-SelectedIds)
        if ($NeedsSelection -and $ids.Count -eq 0) {
            throw 'Select at least one installable resource or choose an installation profile.'
        }
        if ($ids.Count -gt 0) {
            $args.Add('-Resource')
            foreach ($id in $ids) { $args.Add($id) }
        }
        if ($version) {
            $args.Add('-Version')
            $args.Add($version)
        }
    }
    return $args.ToArray()
}

function Set-Busy {
    param([bool]$Busy)
    $script:busy = $Busy
    foreach ($button in $actions.Controls) { $button.Enabled = -not $Busy }
    $script:browseButton.Enabled = -not $Busy
    $script:saveToken.Enabled = -not $Busy
    $script:clearToken.Enabled = -not $Busy
    $script:progress.Style = if ($Busy) { 'Marquee' } else { 'Blocks' }
}

function Start-Command {
    param([string[]]$Arguments, [string]$Description)

    if ($script:busy) { return }
    $pwsh = (Get-Command pwsh -ErrorAction Stop).Source
    $all = [System.Collections.Generic.List[string]]::new()
    foreach ($arg in @('-NoProfile', '-NonInteractive', '-File', $script:cliPath)) { $all.Add($arg) }
    $all.AddRange([string[]]$Arguments)
    $all.Add('-Confirm:$false')
    $script:workerJob = [pscustomobject]@{ FileName = $pwsh; Arguments = $all.ToArray(); Description = $Description }
    Add-Log "Starting $Description..."
    Set-Busy $true
    $script:worker.RunWorkerAsync($script:workerJob)
}

$script:worker = [System.ComponentModel.BackgroundWorker]::new()
$script:worker.add_DoWork({
    param($sender, $eventArgs)
    $job = $eventArgs.Argument
    $start = [System.Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $job.FileName
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($arg in $job.Arguments) { $start.ArgumentList.Add([string]$arg) }
    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $start
    try {
        if (-not $process.Start()) { throw 'Could not start the PS Base command.' }
        $outTask = $process.StandardOutput.ReadToEndAsync()
        $errTask = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        $eventArgs.Result = [pscustomobject]@{
            ExitCode = $process.ExitCode
            Output = $outTask.GetAwaiter().GetResult()
            Error = $errTask.GetAwaiter().GetResult()
            Description = $job.Description
        }
    }
    finally { $process.Dispose() }
})
$script:worker.add_RunWorkerCompleted({
    param($sender, $eventArgs)
    Set-Busy $false
    if ($eventArgs.Error) {
        Add-Log ('ERROR: ' + $eventArgs.Error.Exception.Message)
        [System.Windows.Forms.MessageBox]::Show($form, $eventArgs.Error.Exception.Message, 'PS Base error', 'OK', 'Error') | Out-Null
        return
    }
    $result = $eventArgs.Result
    if ($result.Output) { Add-Log $result.Output.TrimEnd() }
    if ($result.Error) { Add-Log $result.Error.TrimEnd() }
    if ($result.ExitCode -eq 0) { Add-Log "$($result.Description) completed." }
    if ($result.ExitCode -eq 0 -and $result.Description -eq 'Catalog sync') {
        try { Refresh-Catalog; Add-Log 'Resource catalog refreshed.' }
        catch { Add-Log "Catalog reload failed: $($_.Exception.Message)" }
    }
    else {
        Add-Log "$($result.Description) failed with exit code $($result.ExitCode)."
        [System.Windows.Forms.MessageBox]::Show($form, "Command failed. See the log for details.", 'PS Base', 'OK', 'Warning') | Out-Null
    }
})

$script:browseButton.add_Click({
    $dialog = [System.Windows.Forms.FolderBrowserDialog]::new()
    $dialog.Description = 'Select the RedM server root containing server.cfg and resources.'
    if (Test-Path -LiteralPath $script:serverBox.Text -PathType Container) { $dialog.SelectedPath = $script:serverBox.Text }
    if ($dialog.ShowDialog($form) -eq [System.Windows.Forms.DialogResult]::OK) { $script:serverBox.Text = $dialog.SelectedPath }
    $dialog.Dispose()
})

$script:saveToken.add_Click({
    if (-not $script:tokenBox.Text) { return }
    try {
        $secure = ConvertTo-SecureString $script:tokenBox.Text -AsPlainText -Force
        Set-PSBaseGitHubToken -Token $secure | Out-Null
        $secure.Dispose()
        $script:tokenBox.Clear()
        Add-Log 'GitHub token stored using Windows DPAPI for this Windows user. It is not stored in the server folder or logs.'
        [System.Windows.Forms.MessageBox]::Show($form, 'Token saved securely for the current Windows user.', 'GitHub access', 'OK', 'Information') | Out-Null
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show($form, $_.Exception.Message, 'Could not save token', 'OK', 'Error') | Out-Null
    }
})

$script:clearToken.add_Click({
    $answer = [System.Windows.Forms.MessageBox]::Show($form, 'Remove the saved GitHub token?', 'GitHub access', 'YesNo', 'Warning')
    if ($answer -eq [System.Windows.Forms.DialogResult]::Yes) {
        Clear-PSBaseGitHubToken -Confirm:$false
        Add-Log 'Saved GitHub token removed.'
    }
})

$script:profileBox.add_SelectedIndexChanged({
    $script:versionBox.Enabled = ($script:profileBox.SelectedIndex -eq 0)
    if ($script:profileBox.SelectedIndex -gt 0) {
        $script:versionBox.Clear()
        foreach ($item in $script:resourceList.Items) { $item.Checked = $false }
    }
    Update-SelectionPreview
})
$script:versionBox.add_TextChanged({ Update-SelectionPreview })

$script:resourceList.add_ItemCheck({
    param($sender, $eventArgs)
    $item = $sender.Items[$eventArgs.Index]
    if ($eventArgs.NewValue -eq [System.Windows.Forms.CheckState]::Checked -and $item.SubItems[3].Text -ne 'True') {
        $eventArgs.NewValue = [System.Windows.Forms.CheckState]::Unchecked
        return
    }
    if ($eventArgs.NewValue -eq [System.Windows.Forms.CheckState]::Checked -and $script:profileBox.SelectedIndex -gt 0) {
        $script:profileBox.SelectedIndex = 0
    }
    [void]$form.BeginInvoke([Action]{ Update-SelectionPreview })
})

$script:resourceList.add_SelectedIndexChanged({
    if ($script:resourceList.SelectedItems.Count -eq 0) { return }
    $id = [string]$script:resourceList.SelectedItems[0].Tag
    $resource = Get-PSBaseResource -Catalog $script:catalog -Id $id
    $versions = @($resource.releases | ForEach-Object { [string]$_.version })
    $versionText = if ($versions.Count -gt 0) { $versions -join ', ' } else { 'No published releases' }
    $script:notice.Text = "$($resource.name) | $($resource.status) | Versions: $versionText"
})

$script:refreshButton = [System.Windows.Forms.Button]::new()
$script:refreshButton.Text = 'Sync catalog'
$script:refreshButton.Width = 112
$script:refreshButton.Height = 32
$actions.Controls.Add($script:refreshButton)
$script:refreshButton.add_Click({
    try { Start-Command @('-Command', 'sync-catalog') 'Catalog sync' }
    catch { [System.Windows.Forms.MessageBox]::Show($form, $_.Exception.Message, 'Catalog sync', 'OK', 'Error') | Out-Null }
})

function Add-ActionButton {
    param([string]$Text, [int]$X, [scriptblock]$Action, [int]$Width = 100)
    $button = [System.Windows.Forms.Button]::new()
    $button.Text = $Text
    $button.Location = [System.Drawing.Point]::new($X, 474)
    $button.Size = [System.Drawing.Size]::new($Width, 34)
    $actions.Controls.Add($button)
    $button.add_Click($Action)
    return $button
}

[void](Add-ActionButton 'Review plan' 0 {
    try { Start-Command (Get-CommandArgs 'plan' -NeedsSelection) 'Plan' }
    catch { [System.Windows.Forms.MessageBox]::Show($form, $_.Exception.Message, 'Plan', 'OK', 'Warning') | Out-Null }
})
[void](Add-ActionButton 'Install' 0 {
    try {
        if (-not (Test-Path -LiteralPath $script:serverBox.Text.Trim() -PathType Container)) { throw 'Select an existing RedM server folder first.' }
        $args = Get-CommandArgs 'install' -NeedsSelection
        if ([System.Windows.Forms.MessageBox]::Show($form, 'Install selected resources and dependencies? Review the plan first.', 'Confirm install', 'YesNo', 'Question') -eq [System.Windows.Forms.DialogResult]::Yes) {
            Start-Command $args 'Install'
        }
    }
    catch { [System.Windows.Forms.MessageBox]::Show($form, $_.Exception.Message, 'Install', 'OK', 'Warning') | Out-Null }
})
[void](Add-ActionButton 'Update' 0 {
    try {
        if (-not (Test-Path -LiteralPath $script:serverBox.Text.Trim() -PathType Container)) { throw 'Select an existing RedM server folder first.' }
        $args = Get-CommandArgs 'update' -NeedsSelection
        if ([System.Windows.Forms.MessageBox]::Show($form, 'Apply a safe update? Locally modified and untracked files are protected.', 'Confirm update', 'YesNo', 'Question') -eq [System.Windows.Forms.DialogResult]::Yes) {
            Start-Command $args 'Update'
        }
    }
    catch { [System.Windows.Forms.MessageBox]::Show($form, $_.Exception.Message, 'Update', 'OK', 'Warning') | Out-Null }
})
[void](Add-ActionButton 'Status' 0 {
    try {
        if (-not (Test-Path -LiteralPath $script:serverBox.Text.Trim() -PathType Container)) { throw 'Select an existing RedM server folder first.' }
        Start-Command (Get-CommandArgs 'status') 'Status'
    }
    catch { [System.Windows.Forms.MessageBox]::Show($form, $_.Exception.Message, 'Status', 'OK', 'Warning') | Out-Null }
})
[void](Add-ActionButton 'Backups' 0 {
    try {
        if (-not (Test-Path -LiteralPath $script:serverBox.Text.Trim() -PathType Container)) { throw 'Select an existing RedM server folder first.' }
        Start-Command (Get-CommandArgs 'backups') 'Backups'
    }
    catch { [System.Windows.Forms.MessageBox]::Show($form, $_.Exception.Message, 'Backups', 'OK', 'Warning') | Out-Null }
})
[void](Add-ActionButton 'Restore' 0 {
    try {
        if (-not (Test-Path -LiteralPath $script:serverBox.Text.Trim() -PathType Container)) { throw 'Select an existing RedM server folder first.' }
        $id = [Microsoft.VisualBasic.Interaction]::InputBox('Enter the exact Backup ID from the Backups output:', 'Restore backup')
        if (-not $id) { return }
        if ([System.Windows.Forms.MessageBox]::Show($form, "Restore backup '$id'? A safety backup is created first.", 'Confirm restore', 'YesNo', 'Warning') -eq [System.Windows.Forms.DialogResult]::Yes) {
            Start-Command @('-Command','restore','-ServerPath',$script:serverBox.Text.Trim(),'-BackupId',$id.Trim()) 'Restore'
        }
    }
    catch { [System.Windows.Forms.MessageBox]::Show($form, $_.Exception.Message, 'Restore', 'OK', 'Warning') | Out-Null }
})
[void](Add-ActionButton 'Uninstall' 0 {
    try {
        $ids = @(Get-SelectedIds)
        if ($ids.Count -ne 1) { throw 'Check exactly one resource in the list to uninstall it.' }
        if (-not (Test-Path -LiteralPath $script:serverBox.Text.Trim() -PathType Container)) { throw 'Select an existing RedM server folder first.' }
        if ([System.Windows.Forms.MessageBox]::Show($form, "Safely uninstall '$($ids[0])'? Local files are retained and a backup is created.", 'Confirm uninstall', 'YesNo', 'Warning') -eq [System.Windows.Forms.DialogResult]::Yes) {
            Start-Command @('-Command','uninstall','-ServerPath',$script:serverBox.Text.Trim(),'-Resource',$ids[0]) 'Uninstall'
        }
    }
    catch { [System.Windows.Forms.MessageBox]::Show($form, $_.Exception.Message, 'Uninstall', 'OK', 'Warning') | Out-Null }
})
[void](Add-ActionButton 'Recover' 0 {
    try {
        if (-not (Test-Path -LiteralPath $script:serverBox.Text.Trim() -PathType Container)) { throw 'Select an existing RedM server folder first.' }
        $id = [Microsoft.VisualBasic.Interaction]::InputBox('Enter the exact transaction ID:', 'Recover transaction')
        if (-not $id) { return }
        if ([System.Windows.Forms.MessageBox]::Show($form, "Roll back interrupted transaction '$id'?", 'Confirm recovery', 'YesNo', 'Warning') -eq [System.Windows.Forms.DialogResult]::Yes) {
            Start-Command @('-Command','recover','-ServerPath',$script:serverBox.Text.Trim(),'-TransactionId',$id.Trim()) 'Recover'
        }
    }
    catch { [System.Windows.Forms.MessageBox]::Show($form, $_.Exception.Message, 'Recovery', 'OK', 'Warning') | Out-Null }
})

try {
    Refresh-Catalog
    $token = Get-PSBaseGitHubToken
    if ($token) { Add-Log 'A GitHub credential is available for private release downloads.' }
    $token = $null
}
catch {
    [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'PS Base startup error', 'OK', 'Error') | Out-Null
    throw
}

[void]$form.ShowDialog()
$form.Dispose()
