# Dot-sourced by studio.ps1 after the main WPF controls have been resolved.
$script:Iw3Schema=Get-Content -Encoding UTF8 -Raw -LiteralPath (Join-Path $ScriptDirectory 'iw3-settings.json')|ConvertFrom-Json
$script:Iw3Controls=@{}
$script:Iw3Da3Catalog=Get-Content -Encoding UTF8 -Raw -LiteralPath (Join-Path $ScriptDirectory 'iw3-da3-models.json')|ConvertFrom-Json
$script:Iw3Store=Join-Path $Root 'settings/iw3.json'
$script:Iw3Group=[Windows.Controls.GroupBox]::new()
$Iw3Group.Header='IW3 · ОРИГИНАЛЬНЫЙ СТЕРЕОКОНВЕЙЕР'
$Iw3Group.Visibility='Collapsed'
$Iw3Content=[Windows.Controls.StackPanel]::new()
$Iw3Group.Content=$Iw3Content
$Iw3Intro=[Windows.Controls.TextBlock]::new()
$Iw3Intro.Text='Оригинальные RowFlow / MLBW и 12-кадровый Video Inpaint. Выберите исходную depth-модель iw3 или новые DA3 через Studio-провайдер. GAPW/Atlas не применяются. DLSS 5 и интерполяция включаются отдельно. Для ссылок и точных отрезков создаётся lossless-файл (лимит 8 ГиБ); длинное видео лучше открыть локальным файлом целиком.'
$Iw3Intro.TextWrapping='Wrap';$Iw3Intro.Margin='0,0,0,12'
[void]$Iw3Content.Children.Add($Iw3Intro)
$script:Iw3GeometryInfo=[Windows.Controls.TextBlock]::new()
$Iw3GeometryInfo.TextWrapping='Wrap';$Iw3GeometryInfo.Margin='0,0,0,12'
$Iw3GeometryInfo.Foreground=[Windows.Media.BrushConverter]::new().ConvertFromString('#78D9FF')
[void]$Iw3Content.Children.Add($Iw3GeometryInfo)
$Iw3DepthTop=[Windows.Controls.StackPanel]::new()
[void]$Iw3Content.Children.Add($Iw3DepthTop)
$Iw3Buttons=[Windows.Controls.WrapPanel]::new()
foreach($Caption in @('Сохранить настройки iw3','Сбросить','Установить компоненты')){
    $Button=[Windows.Controls.Button]::new();$Button.Content=$Caption
    switch($Caption){
        'Сохранить настройки iw3' {$Button.Add_Click({Save-Iw3Settings;Add-Log 'IW3_SETTINGS_SAVED'})}
        'Сбросить' {$Button.Add_Click({Set-Iw3Settings @{};Update-Iw3Ui})}
        default {$Button.Add_Click({
            if($script:Process){[Windows.MessageBox]::Show('Сначала остановите обработку.','iw3')|Out-Null;return}
            if($script:Iw3InstallProcess -and -not $script:Iw3InstallProcess.HasExited){Add-Log 'Установка iw3 ещё выполняется.';return}
            if($script:Iw3Da3InstallProcess -and -not $script:Iw3Da3InstallProcess.HasExited){Add-Log 'Установка DA3 ещё выполняется.';return}
            $InstallLog=Join-Path $Root 'temp/iw3-install.log'
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $InstallLog)|Out-Null
            $script:Iw3InstallProcess=Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',('"'+(Join-Path $Root 'scripts/Install-Iw3.ps1')+'"')) -WindowStyle Hidden -RedirectStandardOutput $InstallLog -RedirectStandardError ($InstallLog+'.errors') -PassThru
            Add-Log ('Установка iw3 запущена. Журнал: '+$InstallLog)
        })}
    }
    [void]$Iw3Buttons.Children.Add($Button)
}
[void]$Iw3Content.Children.Add($Iw3Buttons)
$Da3Buttons=[Windows.Controls.WrapPanel]::new()
$script:Iw3Da3InstallButton=[Windows.Controls.Button]::new();$Iw3Da3InstallButton.Content='Установить выбранную DA3'
$Iw3Da3InstallButton.Add_Click({
    if($script:Process -or ($script:Iw3InstallProcess -and -not $script:Iw3InstallProcess.HasExited)){
        [Windows.MessageBox]::Show('Дождитесь окончания обработки или установки iw3.','DA3')|Out-Null;return
    }
    $ModelId=Combo-Tag $Iw3Controls['depth_model']
    $Model=@($Iw3Da3Catalog.models|Where-Object id -eq $ModelId)
    if($Model.Count -ne 1){return}
    if($Model[0].license -eq 'CC-BY-NC-4.0'){
        if([Windows.MessageBox]::Show('Модель разрешена только для некоммерческого использования (CC-BY-NC-4.0). Скачать '+$Model[0].name+'?', 'Лицензия DA3','YesNo') -ne 'Yes'){return}
    }
    $script:Iw3Da3InstallLog=Join-Path $Root 'temp/iw3-da3-install.log'
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Iw3Da3InstallLog)|Out-Null
    $script:Iw3Da3InstallProcess=Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',('"'+(Join-Path $Root 'scripts/Install-Iw3Da3.ps1')+'"'),'-Model',$ModelId) -WindowStyle Hidden -RedirectStandardOutput $Iw3Da3InstallLog -RedirectStandardError ($Iw3Da3InstallLog+'.errors') -PassThru
    $Iw3Da3Status.Text='Загрузка '+$Model[0].name+'…';Update-Iw3Ui
})
[void]$Da3Buttons.Children.Add($Iw3Da3InstallButton)
$script:Iw3Da3CancelButton=[Windows.Controls.Button]::new();$Iw3Da3CancelButton.Content='Остановить загрузку DA3';$Iw3Da3CancelButton.IsEnabled=$false
$Iw3Da3CancelButton.Add_Click({
    if($script:Iw3Da3InstallProcess -and -not $script:Iw3Da3InstallProcess.HasExited){
        & taskkill.exe /PID $script:Iw3Da3InstallProcess.Id /T /F 2>$null|Out-Null
        Add-Log 'Загрузка DA3 остановлена. Частичный файл оставлен для продолжения; готовые модели не удалялись.'
    }
})
[void]$Da3Buttons.Children.Add($Iw3Da3CancelButton)
$Da3Preset=[Windows.Controls.Button]::new();$Da3Preset.Content='Старт для кино: DA3 Mono / 518'
$Da3Preset.Add_Click({
    $Current=Get-Iw3Settings;$Current.depth_model='Any_V3_Mono';$Current.resolution=518
    $Current.da3_microbatch=1;$Current.ema_normalize=$true;$Current.scene_detect=$true
    Set-Iw3Settings $Current;Update-Iw3Ui
})
[void]$Da3Buttons.Children.Add($Da3Preset)
[void]$Iw3Content.Children.Add($Da3Buttons)
$script:Iw3Da3Status=[Windows.Controls.TextBlock]::new();$Iw3Da3Status.TextWrapping='Wrap';$Iw3Da3Status.Margin='0,4,0,12'
$Iw3Da3Status.Foreground=[Windows.Media.BrushConverter]::new().ConvertFromString('#75DFC3')
[void]$Iw3Content.Children.Add($Iw3Da3Status)
$Iw3Sections=@{}
foreach($Field in $Iw3Schema.fields){
    if(-not $Iw3Sections.ContainsKey($Field.group)){
        $Section=[Windows.Controls.Expander]::new();$Section.Header=$Field.group
        $Section.Foreground=[Windows.Media.BrushConverter]::new().ConvertFromString('#DCE7F5')
        $Section.IsExpanded=$Field.group -in @('Стерео','Глубина и стабильность','Наши дополнения')
        $Section.Margin='0,8,0,8'
        $Stack=[Windows.Controls.StackPanel]::new();$Stack.Margin='8,8,8,4'
        $Section.Content=$Stack;$Iw3Sections[$Field.group]=$Stack
        [void]$Iw3Content.Children.Add($Section)
    }
    $Stack=if($Field.key -eq 'depth_model'){$Iw3DepthTop}else{$Iw3Sections[$Field.group]}
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
    if($Field.key -eq 'depth_model'){$Help.Text='DA3: выберите модель и установите кнопкой ниже. Параметры depth и стабильности — в одноимённом разделе.'}
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
function Get-Iw3Geometry([int]$Width,[int]$Height,$Settings,[string]$Mode,[string]$Codec){
    # Pure UI counterpart of iw3_worker.plan_geometry; cross-language parity test.
    if($Width-le 0 -or $Height-le 0){throw 'Неизвестно разрешение исходника.'}
    $W=$Width;$H=$Height;$Box=$null
    if($Mode-ne'Source'){
        $Boxes=@{'2160p'=@(3840,2160);'1440p'=@(2560,1440);'1080p'=@(1920,1080);'720p'=@(1280,720);'540p'=@(960,540)}
        if(-not $Boxes.ContainsKey($Mode)){throw 'Неизвестный пресет разрешения.'}
        $BW=$Boxes[$Mode][0];$BH=$Boxes[$Mode][1]
        if($Height-gt$Width){$Swap=$BW;$BW=$BH;$BH=$Swap}
        $Box=@($BW,$BH)
        if([long]$BW*$Height-le[long]$BH*$Width){
            $W=$BW;$H=[int][math]::Max(2,2*[math]::Floor($Height*[double]$BW/$Width/2))
        }else{
            $H=$BH;$W=[int][math]::Max(2,2*[math]::Floor($Width*[double]$BH/$Height/2))
        }
    }
    $InputGeometry=@($W,$H)
    $Vf=if($W-ne$Width -or $H-ne$Height){"scale=${W}:${H}:flags=lanczos"}else{$null}
    $Cap=[int]$Settings.inpaint_max_width
    if($Settings.method.EndsWith('inpaint') -and $Cap-gt 0 -and $W-gt$Cap){
        $Cap+=$Cap%2;$H=[int][math]::Floor(($Cap/[double]$W)*$H);$H+=$H%2;$W=$Cap
    }
    $ContentGeometry=@($W,$H)
    $Pad=[int][math]::Floor([math]::Abs([double]$Settings.ipd_offset)*.01*[math]::Max($W,$H));$Pad-=$Pad%2
    $W+=3*$Pad;$Eye=@($W,$H)
    $Layout=[string]$Settings.layout
    if($Layout-eq'HalfSBS'){$W=[int][math]::Floor($W/2)}
    if($Layout-eq'HalfOU'){$H=[int][math]::Floor($H/2)}
    $PackedEye=@($W,$H)
    $Output=if($Layout.EndsWith('SBS')){@(($W*2),$H)}else{@($W,($H*2))}
    $Limit=if($Codec-eq'H265'){8192}else{4096}
    $Errors=[Collections.Generic.List[string]]::new()
    if([math]::Min($Output[0],$Output[1])-lt 2 -or $Output[0]%2 -or $Output[1]%2){
        $Errors.Add("IW3: размер $($Output[0])×$($Output[1]) несовместим с 4:2:0; выберите пресет разрешения с чётными размерами.")
    }
    if([math]::Max($Output[0],$Output[1])-gt$Limit){
        $Errors.Add("IW3: $Layout даёт $($Output[0])×$($Output[1]), предел $Codec в portable — ${Limit}×${Limit}. Выберите меньший пресет, другую стереоупаковку или H.265; качество автоматически не уменьшается.")
    }
    if($Codec-eq'H264' -and $Settings.pix_fmt-ne'yuv420p'){$Errors.Add('IW3: для 10-bit выберите H.265.')}
    return [pscustomobject]@{source_geometry=@($Width,$Height);input_geometry=$InputGeometry;content_eye_geometry=$ContentGeometry;eye_geometry=$Eye;packed_eye_geometry=$PackedEye;output_geometry=$Output;bounds=$Box;output_mode=$Mode;layout=$Layout;codec=$Codec;encoder_limit=$Limit;video_filter=$Vf;valid=($Errors.Count-eq 0);errors=@($Errors.ToArray())}
}
function Show-Iw3Geometry($Plan){
    $Iw3GeometryInfo.Text="Исходник $($Plan.source_geometry[0])×$($Plan.source_geometry[1]) → ракурс $($Plan.eye_geometry[0])×$($Plan.eye_geometry[1]) → файл $($Plan.output_geometry[0])×$($Plan.output_geometry[1]) ($($Plan.layout), $($Plan.codec)).`n4K — рамка 3840×2160 на глаз с сохранением пропорций; для портретного видео рамка поворачивается. Source — исходный размер."
    if(-not $Plan.valid){$Iw3GeometryInfo.Text+="`n"+($Plan.errors -join "`n")}
    $Iw3GeometryInfo.Foreground=[Windows.Media.BrushConverter]::new().ConvertFromString($(if($Plan.valid){'#78D9FF'}else{'#FF9D96'}))
}
function Update-Iw3Geometry {
    if(-not $Iw3GeometryInfo -or -not $Iw3Controls.ContainsKey('target_fps') -or -not $Iw3Controls['target_fps'].SelectedItem){return}
    if(-not $script:SourceInfo -or $script:SourceInfo.input -ne $InputBox.Text){
        $Iw3GeometryInfo.Text='Расчёт: исходник → каждый глаз → готовый файл. Для ссылки точный размер проверяется сразу после открытия потока, до DLSS и загрузки модели. 4K вписывается в 3840×2160 на глаз без обрезки.'
        $Iw3GeometryInfo.Foreground=[Windows.Media.BrushConverter]::new().ConvertFromString('#78D9FF');return
    }
    if(-not $ModeCombo.SelectedItem -or -not $CodecCombo.SelectedItem){return}
    Show-Iw3Geometry (Get-Iw3Geometry $SourceInfo.width $SourceInfo.height (Get-Iw3Settings) (Combo-Tag $ModeCombo) (Combo-Tag $CodecCombo))
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
    $ModelId=Combo-Tag $Iw3Controls['depth_model']
    $Model=@($Iw3Da3Catalog.models|Where-Object id -eq $ModelId)
    $Installing=$script:Iw3Da3InstallProcess -and -not $script:Iw3Da3InstallProcess.HasExited
    $Iw3Da3InstallButton.IsEnabled=($Model.Count -eq 1 -and -not $Installing)
    $Iw3Da3CancelButton.IsEnabled=[bool]$Installing
    foreach($Key in @('da3_microbatch','da3_depth_shift')){if($Iw3Controls.ContainsKey($Key)){$Iw3Controls[$Key].IsEnabled=$Model.Count -eq 1}}
    if($Iw3Controls.ContainsKey('da3_sky_strength')){$Iw3Controls['da3_sky_strength'].IsEnabled=$ModelId -eq 'Any_V3_Mono'}
    if($Iw3Controls.ContainsKey('depth_aa')){
        $Iw3Controls['depth_aa'].IsEnabled=-not $ModelId.StartsWith('Studio_DA3')
        if(-not $Iw3Controls['depth_aa'].IsEnabled){$Iw3Controls['depth_aa'].IsChecked=$false}
    }
    Update-Iw3Geometry
    if(-not $Installing){
        if($Model.Count -eq 1){
            $M=$Model[0];$Status='Нужно установить'
            $Marker=Join-Path $Root ('models/iw3/da3-status/'+$ModelId+'.json')
            $Weights=Join-Path $Root $M.path
            if((Test-Path -LiteralPath $Marker) -and (Test-Path -LiteralPath $Weights)){
                try{
                    $Saved=Get-Content -Encoding UTF8 -Raw -LiteralPath $Marker|ConvertFrom-Json
                    $File=Get-Item -LiteralPath $Weights
                    $EpochTicks=[datetime]::SpecifyKind([datetime]'1970-01-01',[DateTimeKind]::Utc).Ticks
                    $MtimeNs=($File.LastWriteTimeUtc.Ticks-$EpochTicks)*[long]100
                    if($Saved.sha256 -eq $M.sha256 -and $File.Length -eq $M.bytes -and [long]$Saved.mtime_ns -eq $MtimeNs){$Status='Установлена · SHA-256 проверен при установке'}
                }catch{}
            }
            $Iw3Da3Status.Text=('{0}: {1} · {2:N2} ГБ · {3}. {4}' -f $M.name,$Status,($M.bytes/1e9),$M.license,$M.help)
        }else{$Iw3Da3Status.Text='DA3: выберите Mono / Small / Base / Large 1.1 / Giant 1.1 в списке моделей выше.'}
    }
}

function Update-Iw3Da3Install {
    if(-not $script:Iw3Da3InstallProcess){return}
    if(Test-Path -LiteralPath $Iw3Da3InstallLog){
        $Lines=Get-Content -Encoding UTF8 -Tail 4 -LiteralPath $Iw3Da3InstallLog -ErrorAction SilentlyContinue
        $Line=@($Lines|Where-Object {$_ -like 'IW3_DA3_INSTALL *'})|Select-Object -Last 1
        if($Line){try{
            $P=$Line.Substring(16)|ConvertFrom-Json
            $Iw3Da3Status.Text=('DA3 · {0} · {1}% · {2:N1} / {3:N1} МБ · {4} МБ/с' -f $P.phase,$P.percent,($P.bytes/1e6),($P.total/1e6),$P.mbps)
        }catch{}}
    }
    if($Iw3Da3InstallProcess.HasExited){
        $Code=$Iw3Da3InstallProcess.ExitCode;$Iw3Da3InstallProcess.Dispose();$script:Iw3Da3InstallProcess=$null
        Update-Iw3Ui
        if($Code -ne 0){$Iw3Da3Status.Text='Ошибка установки DA3. Подробности: temp/iw3-da3-install.log.errors';Add-Log $Iw3Da3Status.Text}
        else{Add-Log 'DA3 установлена, SHA-256 проверен.'}
    }
}
$Iw3Saved=@{}
if(Test-Path -LiteralPath $Iw3Store){try{$Loaded=Get-Content -Encoding UTF8 -Raw -LiteralPath $Iw3Store|ConvertFrom-Json;foreach($Property in $Loaded.PSObject.Properties){$Iw3Saved[$Property.Name]=$Property.Value}}catch{}}
Set-Iw3Settings $Iw3Saved
foreach($Key in @('ipd_offset','inpaint_max_width')){$Iw3Controls[$Key].Add_ValueChanged({Update-Iw3Geometry})}
$InputBox.Add_TextChanged({Update-Iw3Geometry})
Update-Iw3Geometry
