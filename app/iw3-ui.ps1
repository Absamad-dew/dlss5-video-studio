# Dot-sourced by studio.ps1 after the main WPF controls have been resolved.
$script:Iw3Schema=Get-Content -Encoding UTF8 -Raw -LiteralPath (Join-Path $ScriptDirectory 'iw3-settings.json')|ConvertFrom-Json
$script:Iw3Controls=@{}
$script:Iw3Store=Join-Path $Root 'settings/iw3.json'
$script:Iw3Group=[Windows.Controls.GroupBox]::new()
$Iw3Group.Header='IW3 · ОРИГИНАЛЬНЫЙ СТЕРЕОКОНВЕЙЕР'
$Iw3Group.Visibility='Collapsed'
$Iw3Content=[Windows.Controls.StackPanel]::new()
$Iw3Group.Content=$Iw3Content
$Iw3Intro=[Windows.Controls.TextBlock]::new()
$Iw3Intro.Text='Оригинальные RowFlow / MLBW и 12-кадровый Video Inpaint. Наши depth/GAPW/Atlas-коррекции не применяются. DLSS 5 и интерполяция доступны отдельно и изначально выключены. Для ссылок и точных отрезков создаётся lossless-файл (лимит 8 ГиБ); длинные видео лучше открыть локальным файлом целиком.'
$Iw3Intro.TextWrapping='Wrap';$Iw3Intro.Margin='0,0,0,12'
[void]$Iw3Content.Children.Add($Iw3Intro)
$Iw3Buttons=[Windows.Controls.WrapPanel]::new()
foreach($Caption in @('Сохранить настройки iw3','Сбросить','Установить компоненты')){
    $Button=[Windows.Controls.Button]::new();$Button.Content=$Caption
    switch($Caption){
        'Сохранить настройки iw3' {$Button.Add_Click({Save-Iw3Settings;Add-Log 'IW3_SETTINGS_SAVED'})}
        'Сбросить' {$Button.Add_Click({Set-Iw3Settings @{};Update-Iw3Ui})}
        default {$Button.Add_Click({
            if($script:Process){[Windows.MessageBox]::Show('Сначала остановите обработку.','iw3')|Out-Null;return}
            if($script:Iw3InstallProcess -and -not $script:Iw3InstallProcess.HasExited){Add-Log 'Установка iw3 ещё выполняется.';return}
            $InstallLog=Join-Path $Root 'temp/iw3-install.log'
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $InstallLog)|Out-Null
            $script:Iw3InstallProcess=Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',('"'+(Join-Path $Root 'scripts/Install-Iw3.ps1')+'"')) -WindowStyle Hidden -RedirectStandardOutput $InstallLog -RedirectStandardError ($InstallLog+'.errors') -PassThru
            Add-Log ('Установка iw3 запущена. Журнал: '+$InstallLog)
        })}
    }
    [void]$Iw3Buttons.Children.Add($Button)
}
[void]$Iw3Content.Children.Add($Iw3Buttons)
$Iw3Sections=@{}
foreach($Field in $Iw3Schema.fields){
    if(-not $Iw3Sections.ContainsKey($Field.group)){
        $Section=[Windows.Controls.Expander]::new();$Section.Header=$Field.group
        $Section.Foreground=[Windows.Media.BrushConverter]::new().ConvertFromString('#DCE7F5')
        $Section.IsExpanded=$Field.group -in @('Стерео','Наши дополнения')
        $Section.Margin='0,8,0,8'
        $Stack=[Windows.Controls.StackPanel]::new();$Stack.Margin='8,8,8,4'
        $Section.Content=$Stack;$Iw3Sections[$Field.group]=$Stack
        [void]$Iw3Content.Children.Add($Section)
    }
    $Stack=$Iw3Sections[$Field.group]
    $Label=[Windows.Controls.TextBlock]::new();$Label.Text=$Field.label;$Label.Margin='0,6,0,2'
    $Label.Foreground=[Windows.Media.BrushConverter]::new().ConvertFromString('#DCE7F5')
    $Label.ToolTip=$Field.help;[void]$Stack.Children.Add($Label)
    switch($Field.type){
        'choice' {
            $Control=[Windows.Controls.ComboBox]::new()
            foreach($Option in $Field.options){$Item=[Windows.Controls.ComboBoxItem]::new();$Item.Content=$Option.label;$Item.Tag=[string]$Option.value;[void]$Control.Items.Add($Item)}
            $Control.Add_SelectionChanged({Update-Iw3Ui})
        }
        'bool' {$Control=[Windows.Controls.CheckBox]::new();$Control.Content=$Field.label}
        default {
            $Control=[Windows.Controls.Slider]::new();$Control.Minimum=$Field.min;$Control.Maximum=$Field.max
            $Control.TickFrequency=$Field.step;$Control.IsSnapToTickEnabled=$true
            $Number=[Windows.Controls.TextBlock]::new();$Number.HorizontalAlignment='Right'
            $Number.Foreground=[Windows.Media.BrushConverter]::new().ConvertFromString('#75DFC3')
            $Binding=[Windows.Data.Binding]::new('Value');$Binding.Source=$Control;$Binding.StringFormat='{0:0.##}'
            [void]$Number.SetBinding([Windows.Controls.TextBlock]::TextProperty,$Binding)
            [void]$Stack.Children.Add($Number)
        }
    }
    $Control.ToolTip=$Field.help
    [Windows.Automation.AutomationProperties]::SetName($Control,$Field.label)
    $Iw3Controls[$Field.key]=$Control
    [void]$Stack.Children.Add($Control)
    $Help=[Windows.Controls.TextBlock]::new();$Help.Text=$Field.help;$Help.TextWrapping='Wrap';$Help.FontSize=11;$Help.Opacity=.72;$Help.Margin='0,0,0,8'
    $Help.Foreground=[Windows.Media.BrushConverter]::new().ConvertFromString('#BACCE2')
    [void]$Stack.Children.Add($Help)
}
$Parent=$VrGroup.Parent
$Index=$Parent.Children.IndexOf($VrGroup)
$Parent.Children.Insert($Index+1,$Iw3Group)

function Get-Iw3Settings {
    $Values=[ordered]@{}
    foreach($Field in $Iw3Schema.fields){
        $Control=$Iw3Controls[$Field.key]
        $Values[$Field.key]=switch($Field.type){'choice'{Combo-Tag $Control}'bool'{[bool]$Control.IsChecked}default{[double]$Control.Value}}
    }
    return $Values
}
function Set-Iw3Settings($Values){
    foreach($Field in $Iw3Schema.fields){
        $Value=if($Values.Contains($Field.key)){$Values[$Field.key]}else{$Field.default}
        $Control=$Iw3Controls[$Field.key]
        switch($Field.type){'choice'{Select-StringTag $Control ([string]$Value)}'bool'{$Control.IsChecked=[bool]$Value}default{$Control.Value=[double]$Value}}
    }
}
function Save-Iw3Settings {
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Iw3Store)|Out-Null
    [IO.File]::WriteAllText($Iw3Store,((Get-Iw3Settings)|ConvertTo-Json -Depth 5),[Text.UTF8Encoding]::new($false))
}
function Update-Iw3Ui {
    if(-not $Iw3Controls.ContainsKey('dlss_mode') -or -not $Iw3Controls['dlss_mode'].SelectedItem){return}
    $Active=(Get-WorkspaceMode)-eq'IW3'
    if($Active){
        $NeuralGroup.IsEnabled=(Combo-Tag $Iw3Controls['dlss_mode'])-ne'Off'
        $PerformanceCombo.IsEnabled=$NeuralGroup.IsEnabled
        $NeuralGroup.Header='DLSS 5 · НАСТРОЙКИ ДОПОЛНИТЕЛЬНОГО ПРОХОДА ПЕРЕД IW3'
    }
    $Method=Combo-Tag $Iw3Controls['method']
    foreach($Key in @('mask_inner_dilation','mask_outer_dilation','inpaint_max_width')){if($Iw3Controls.ContainsKey($Key)){$Iw3Controls[$Key].IsEnabled=$Method.EndsWith('inpaint')}}
    if($Iw3Controls.ContainsKey('warp_steps')){$Iw3Controls['warp_steps'].IsEnabled=$Method.StartsWith('row_flow')}
}
$Iw3Saved=@{}
if(Test-Path -LiteralPath $Iw3Store){try{$Loaded=Get-Content -Encoding UTF8 -Raw -LiteralPath $Iw3Store|ConvertFrom-Json;foreach($Property in $Loaded.PSObject.Properties){$Iw3Saved[$Property.Name]=$Property.Value}}catch{}}
Set-Iw3Settings $Iw3Saved
