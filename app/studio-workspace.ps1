# Presentation only. Existing controls, values, event handlers and processing
# contracts are retained; the catalogue is arranged before WPF creates a tree.
function ConvertTo-StudioWorkspaceXaml([string]$Catalogue) {
    $Old=[xml]$Catalogue
    $OriginalNames=@($Old.SelectNodes('//*[@*[local-name()="Name"]]')|ForEach-Object {$_.GetAttribute('Name','http://schemas.microsoft.com/winfx/2006/xaml')})
    $Shell=[xml](Get-Content -LiteralPath (Join-Path $ScriptDirectory 'studio-shell.xaml') -Encoding UTF8 -Raw)
    $Theme=[xml](Get-Content -LiteralPath (Join-Path $ScriptDirectory 'studio-theme.xaml') -Encoding UTF8 -Raw)
    $Ns='http://schemas.microsoft.com/winfx/2006/xaml/presentation'
    $Xns='http://schemas.microsoft.com/winfx/2006/xaml'
    $Resources=$Shell.SelectSingleNode('//*[local-name()="Window.Resources"]')
    $Resources.RemoveAll();[void]$Resources.AppendChild($Shell.ImportNode($Theme.DocumentElement,$true))
    function Old-Control([string]$Name){$Old.SelectSingleNode("//*[@*[local-name()='Name']='$Name']")}
    function Slot([string]$Name){$Shell.SelectSingleNode("//*[@*[local-name()='Name']='$Name']")}
    function Put-Control($Node,[string]$Page){
        if(-not $Node){throw "Missing UI control for $Page"}
        [void](Slot $Page).AppendChild($Shell.ImportNode($Node,$true))
        [void]$Node.ParentNode.RemoveChild($Node)
    }
    function Card($Node,[string]$Page,[string]$Title){
        $Group=$Old.CreateElement('GroupBox',$Ns);$Group.SetAttribute('Header',$Title)
        if($Node.LocalName -eq 'Expander'){
            foreach($Child in @($Node.ChildNodes)){[void]$Group.AppendChild($Child)}
            [void]$Node.ParentNode.RemoveChild($Node)
        }else{[void]$Group.AppendChild($Node)}
        [void](Slot $Page).AppendChild($Shell.ImportNode($Group,$true))
    }
    # Large VR expanders become real pages; no changes to their settings.
    $Fill= (Old-Control 'VRGenerativeBackendCombo').SelectSingleNode('ancestor::*[local-name()="Expander"][1]')
    Card $Fill 'PageFill' 'Восстановление скрытого фона'
    $Depth=(Old-Control 'VRQualityPipelineCombo').SelectSingleNode('ancestor::*[local-name()="Expander"][1]')
    Card $Depth 'PageDepth' 'Общая глубина и аппаратный конвейер'
    $Fine=Old-Control 'VRFineStereoExpander'
    $Fine.SetAttribute('Header','Границы, заполнение и комфорт')
    $Fine.SetAttribute('IsExpanded','True')
    # Split the former 35-control expander into short, directly selectable tabs.
    $Body=$Fine.SelectSingleNode('.//*[local-name()="StackPanel"][1]')
    $Tabs=$Old.CreateElement('TabControl',$Ns)
    $Current=$null
    foreach($Node in @($Body.ChildNodes)){
        if($Node.NodeType -ne 'Element'){continue}
        $Xml=$Node.OuterXml
        $Heading=if(-not $Current){'Метод и ракурсы'}elseif($Xml.Contains('VRDepthGammaValue')){'Границы и слои'}elseif($Xml.Contains('VRComfortValue')){'Комфорт'}else{$null}
        if($Heading){
            $Tab=$Old.CreateElement('TabItem',$Ns);$Tab.SetAttribute('Header',$Heading)
            $Current=$Old.CreateElement('StackPanel',$Ns);[void]$Tab.AppendChild($Current);[void]$Tabs.AppendChild($Tab)
        }
        [void]$Current.AppendChild($Node)
    }
    [void]$Body.AppendChild($Tabs)
    Put-Control $Fine 'PageComfort'
    $Motion=(Old-Control 'GuideWidthSlider').SelectSingleNode('ancestor::*[local-name()="Expander"][1]')
    Card $Motion 'PageMotion' 'Движение и глубина для реалтайма'
    # These controls otherwise only appeared inside the VR-only group, although
    # the shared depth model also configures recording and realtime.
    $DepthField= (Old-Control 'DepthModelCombo').ParentNode
    $DepthRow=$DepthField.ParentNode
    Card $DepthField 'PageMotion' 'Модель служебной глубины'
    $DepthRow.SelectSingleNode('*[local-name()="Grid.ColumnDefinitions"]').RemoveAll()
    [void]$DepthRow.SelectSingleNode('*[local-name()="Grid.ColumnDefinitions"]').AppendChild($Old.CreateElement('ColumnDefinition',$Ns))
    $DepthRow.SelectSingleNode('*[local-name()="StackPanel"]').RemoveAttribute('Grid.Column')
    $Source=$Old.SelectSingleNode('//*[local-name()="GroupBox"][@Header="ВИДЕО"]')
    $Source.SetAttribute('Header','Источник видео')
    Put-Control $Source 'PageSource'
    foreach($Entry in @(
        @('QuickGroup','PageSource','Быстрый старт'),@('RangeGroup','PageSource','Отрезок видео'),
        @('OutputGroup','PageOutput','Разрешение и качество вывода'),@('RealtimePanel','PagePlayer','Плавность, звук и буфер'),
        @('VrGroup','PageStereo','Формат и сила 3D'),@('NeuralGroup','PageNeural','DLSS 5 · нейронный рендеринг'),
        @('AdvancedParams','PageNeural','Калибровка движения, глубины и цвета'),@('UpscalerGroup','PageUpscale','Внешний нейронный апскейл'),
        @('StageGroup','PageUpscale','Порядок обработки'),@('RecordingPanel','PageMotion','Карты движения и глубины для записи')
    )){
        $Control=Old-Control $Entry[0];$Control.SetAttribute('Header',$Entry[2]);Put-Control $Control $Entry[1]
    }
    # Uniform typography; long explanations remain available via the help switch.
    foreach($Node in $Shell.SelectNodes('//*[@Header]')){
        $Header=$Node.GetAttribute('Header')
        if($Header.Length -gt 12 -and $Header -ceq $Header.ToUpperInvariant()){
            $Node.SetAttribute('Header',$Header.Substring(0,1)+$Header.Substring(1).ToLowerInvariant())
        }
    }
    $Expert=Slot 'ExpertCheck';$Expert.SetAttribute('Visibility','Collapsed')
    $Labels=@{'NR Intensity'='Общая интенсивность · Intensity';'Local Tone'='Локальный тон';'Local Structure · окружение'='Детализация окружения · Local Structure';'Skin Structure · персонажи'='Детализация персонажей · Skin Structure';'NR Preset'='Пресет рендеринга';'NR Style'='Стиль рендеринга';'Motion Scale X'='Масштаб движения по горизонтали';'Motion Scale Y'='Масштаб движения по вертикали';'Depth Convention'='Направление глубины';'HDR Transfer'='Передача HDR';'Color Strength'='Насыщенность цвета';'Paper-White Scale'='Яркость белого HDR';'Motion backend'='Расчёт движения';'Motion preset'='Точность движения'}
    foreach($TextNode in $Shell.SelectNodes('//*[local-name()="TextBlock"][@Text]')){
        $Text=$TextNode.GetAttribute('Text');if($Labels.ContainsKey($Text)){$TextNode.SetAttribute('Text',$Labels[$Text])}
    }
    # The old catalogue contains local neon colours which override implicit
    # styles. Normalize only the settings surface, not runtime warning states.
    $Settings=Slot 'PagesHost'
    foreach($Node in $Settings.SelectNodes('.//*[@Foreground]')){
        $Node.SetAttribute('Foreground','#D4D6DC')
        if($Node.LocalName-eq'TextBlock'){
            $Name=$Node.GetAttribute('Name',$Xns)
            if($Name.EndsWith('Value')){$Node.SetAttribute('Foreground','#ECEDEF');$Node.SetAttribute('FontFamily','Consolas')}
            elseif($Node.GetAttribute('FontWeight')-ne'SemiBold'){$Node.SetAttribute('Foreground','#ADB1BA')}
        }
    }
    foreach($Node in $Settings.SelectNodes('.//*[local-name()="Border"]')){
        if($Node.HasAttribute('Background')){$Node.SetAttribute('Background','#292B30')}
        if($Node.HasAttribute('BorderBrush')){$Node.SetAttribute('BorderBrush','#45474E')}
        if($Node.HasAttribute('CornerRadius')){$Node.SetAttribute('CornerRadius','3')}
    }
    foreach($Node in $Settings.SelectNodes('.//*[local-name()="GroupBox" or local-name()="Expander" or local-name()="TabControl"]')){
        $Node.RemoveAttribute('Foreground');$Node.RemoveAttribute('Background');$Node.RemoveAttribute('BorderBrush')
    }
    (Slot 'SourceResolutionText').SetAttribute('FontSize','13')
    (Slot 'SourceResolutionText').SetAttribute('Foreground','#D4D6DC')
    $Input=Slot 'InputBox';$Input.SetAttribute('Margin','0');$Input.SetAttribute('Height','32')
    (Slot 'SourceResolutionText').ParentNode.ParentNode.SetAttribute('Margin','0,8,0,12')
    foreach($Name in @('OutputBox','PresetBox')){
        $Control=Slot $Name;$Control.SetAttribute('Margin','0');$Control.SetAttribute('Height','32')
        $Control.ParentNode.SetAttribute('Margin','0,4,0,8')
        foreach($Column in @($Control.ParentNode.SelectNodes('*[local-name()="Grid.ColumnDefinitions"]/*'))|Select-Object -Skip 1){$Column.SetAttribute('Width','Auto')}
    }
    foreach($Name in @('BrowseOutput','SavePreset','DeletePreset')){
        $Control=Slot $Name;$Control.SetAttribute('Height','32');$Control.SetAttribute('Margin','6,0,0,0');$Control.SetAttribute('Padding','12,4')
        $Control.SetAttribute('MinWidth',$(if($Name-eq'BrowseOutput'){'42'}else{'88'}))
    }
    foreach($Name in @('StartBox','FramesBox')){(Slot $Name).SetAttribute('Width','160');(Slot $Name).SetAttribute('HorizontalAlignment','Left')}
    foreach($Name in @('BrowseInput','PasteInput')){
        $Button=Slot $Name;$Button.SetAttribute('Height','32');$Button.SetAttribute('Margin','6,0,0,0');$Button.SetAttribute('Padding','8,4')
    }
    # Compact inspector rows only on full-width panels. Nested two-column
    # panels retain their stacked layout, so they remain usable in narrow views.
    foreach($Slider in @($Settings.SelectNodes('.//*[local-name()="Slider"]'))){
        $Parent=$Slider.ParentNode
        if($Parent.LocalName-ne'StackPanel' -or $Parent.ParentNode.LocalName-eq'Grid'){continue}
        $Row=$Slider.PreviousSibling
        while($Row -and $Row.NodeType-ne'Element'){$Row=$Row.PreviousSibling}
        if(-not $Row -or $Row.LocalName-ne'Grid'){continue}
        $Texts=@($Row.SelectNodes('./*[local-name()="TextBlock"]'))
        if($Texts.Count-ne 2 -or $Row.SelectNodes('./*').Count-ne 3){continue}
        $Columns=$Row.SelectSingleNode('./*[local-name()="Grid.ColumnDefinitions"]');if(-not $Columns){continue}
        $Columns.RemoveAll()
        foreach($Width in @('1.15*','1.6*','62')){$Column=$Shell.CreateElement('ColumnDefinition',$Ns);$Column.SetAttribute('Width',$Width);[void]$Columns.AppendChild($Column)}
        $Row.SetAttribute('Tag','SettingRow');$Row.SetAttribute('Margin','0,2,0,4')
        $Texts[0].SetAttribute('Margin','0,0,12,0');$Texts[0].SetAttribute('VerticalAlignment','Center')
        $Texts[1].SetAttribute('Grid.Column','2');$Texts[1].SetAttribute('VerticalAlignment','Center')
        $Slider.SetAttribute('Grid.Column','1');$Slider.SetAttribute('Margin','0,0,14,0')
        $Slider.SetAttribute('AutomationProperties.Name',$Texts[0].GetAttribute('Text'))
        [void]$Row.AppendChild($Slider)
    }
    # Exact identities are an invariant: every old runtime-bound name survives.
    foreach($Name in $OriginalNames){
        if(-not (Slot $Name) -and $Name -notin @('B')){throw "UI redesign lost named element: $Name"}
    }
    return $Shell.OuterXml
}

function Initialize-StudioWorkspace {
    foreach($Name in @('WorkspaceTitle','WorkspaceSubtitle','SectionNav','SettingsSearch','SearchWatermark','SourceSummary','SourceShortcut','JournalButton','SearchResultsPane','SearchResults','SearchHint','SettingsScroll','PagesHost','HelpCard','InlineHelpCheck','PreviewSplitter','ReviewTabs','PreviewSeek','PreviewTime')){
        Set-Variable -Scope Script -Name $Name -Value $Window.FindName($Name)
    }
    $script:StudioPages=[ordered]@{}
    foreach($Page in $PagesHost.Children){if($Page.Tag){$script:StudioPages[[string]$Page.Tag]=$Page}}
    # iw3 controls are created dynamically after the catalogue is loaded.
    if($Iw3Group.Parent){[void]$Iw3Group.Parent.Children.Remove($Iw3Group)}
    [void]$script:StudioPages['IW3'].Children.Add($Iw3Group)
    $script:StudioSections=[ordered]@{
        Source=@('Видео и диапазон','Локальный файл или ссылка. Все служебные карты программа подготовит сама.')
        Simple=@('Быстрая настройка','Общий профиль и несколько основных параметров. Остальное настроится при применении профиля.')
        Output=@('Выход и качество','Разрешение результата, нагрузка на GPU и параметры кодирования.')
        Player=@('Плеер и буфер','Запас готовых кадров, плавность, генерация кадров и звук.')
        Stereo=@('Формат и сила 3D','Выберите упаковку для шлема, силу объёма и расположение плоскости фокуса.')
        Depth=@('Глубина и конвейер','Одна карта глубины для DLSS 5 и VR. Качество модели и использование памяти.')
        Comfort=@('Стерео и комфорт','Метод построения глаз, защита силуэтов и комфортный диапазон параллакса.')
        Fill=@('Восстановление фона','Перенос настоящих деталей из соседних кадров и дорисовка оставшихся областей.')
        IW3=@('Параметры IW3','Самостоятельный стереоконвейер IW3. Наши дополнения включаются отдельно.')
        Neural=@('DLSS 5','Интенсивность рендеринга, детализация окружения и персонажей.')
        Upscale=@('Апскейл и порядок','Необязательные модели восстановления и очередность нейронных проходов.')
        Motion=@('Движение и ресурсы','Служебная глубина, оптический поток и ручная настройка производительности.')
    }
    $script:StudioModePages=@{
        Realtime=@('Source','Simple','Output','Player','Neural','Upscale','Motion')
        Recording=@('Source','Simple','Output','Neural','Upscale','Motion')
        VR=@('Source','Simple','Output','Stereo','Depth','Comfort','Fill','Neural','Upscale','Motion')
        IW3=@('Source','Simple','Output','IW3','Neural')
    }
    $script:StudioPageMemory=@{};$script:StudioActiveMode='';$script:StudioActivePage='Source'
    $script:StudioScrollMemory=@{};$script:StudioSearchIndex=[Collections.Generic.List[object]]::new()
    $script:StudioHelpNodes=[Collections.Generic.List[object]]::new()
    $script:StudioUiReady=$true
    $BrowseInput.Content='Файл…';$BrowseInput.Parent.ColumnDefinitions[1].Width=[Windows.GridLength]::new(85)
    $QuickGroup.Content.Children[0].Text='Выберите готовый набор параметров, затем уточните его в разделах слева. Ручные изменения сохраняют остальные настройки сценария.'
    $Iw3Group.Header='IW3 · модели, стерео и дополнения'
    $InputBox.SetValue([Windows.Automation.AutomationProperties]::NameProperty,'Видеофайл или ссылка')
    $OutputBox.SetValue([Windows.Automation.AutomationProperties]::NameProperty,'Папка результата')
    $script:StudioToolTips=@{}
    # Explicit tooltips inherit the theme even when WPF creates a separate popup.
    foreach($Control in @(Get-StudioLogicalChildren $Window)){
        if($Control -is [Windows.FrameworkElement] -and $Control.ToolTip -is [string]){
            $Text=[string]$Control.ToolTip
            $Tip=[Windows.Controls.ToolTip]::new();$Tip.Style=$Window.Resources[[Windows.Controls.ToolTip]];$Tip.Content=$Text
            $script:StudioToolTips[$Control]=$Text;$Control.ToolTip=$Tip
        }
    }
    $SectionNav.Add_SelectionChanged({
        if(-not $script:StudioNavigating -and $SectionNav.SelectedItem){Show-StudioSection ([string]$SectionNav.SelectedItem.Tag)}
    })
    $SourceShortcut.Add_Click({Show-StudioSection 'Source';$InputBox.Focus()|Out-Null})
    $JournalButton.Add_Click({Set-StudioReviewPane $true;$ReviewTabs.SelectedIndex=1})
    $SettingsSearch.Add_TextChanged({Update-StudioSearch})
    $SettingsSearch.Add_PreviewKeyDown({param($Sender,$EventArgs)
        if($EventArgs.Key -eq 'Down' -and $SearchResults.Items.Count){$SearchResults.SelectedIndex=0;$SearchResults.Focus()|Out-Null;$EventArgs.Handled=$true}
        elseif($EventArgs.Key -eq 'Return' -and $SearchResults.Items.Count){Open-StudioSearchResult $SearchResults.Items[0];$EventArgs.Handled=$true}
        elseif($EventArgs.Key -eq 'Escape'){$SettingsSearch.Clear();$EventArgs.Handled=$true}
    })
    $SearchResults.Add_PreviewKeyDown({param($Sender,$EventArgs)if($EventArgs.Key -eq 'Return' -and $SearchResults.SelectedItem){Open-StudioSearchResult $SearchResults.SelectedItem;$EventArgs.Handled=$true}})
    $SearchResults.Add_PreviewMouseLeftButtonUp({if($SearchResults.SelectedItem){Open-StudioSearchResult $SearchResults.SelectedItem}})
    $Window.Add_PreviewKeyDown({param($Sender,$EventArgs)
        if($EventArgs.Key -eq 'K' -and ([Windows.Input.Keyboard]::Modifiers -band [Windows.Input.ModifierKeys]::Control)){$SettingsSearch.Focus()|Out-Null;$SettingsSearch.SelectAll();$EventArgs.Handled=$true}
    })
    $InputBox.Add_TextChanged({Update-StudioSourceSummary})
    $InlineHelpCheck.Add_Click({Update-StudioInlineHelp})
    $Preview.Add_MediaOpened({
        if($Preview.NaturalDuration.HasTimeSpan){$PreviewSeek.Maximum=$Preview.NaturalDuration.TimeSpan.TotalSeconds;$PreviewSeek.IsEnabled=$true}
    })
    $Preview.Add_MediaFailed({param($Sender,$EventArgs)
        $PreviewSeek.IsEnabled=$false;$Placeholder.Visibility='Visible'
        Add-Log ('Встроенный просмотр не поддерживает этот файл: '+$EventArgs.ErrorException.Message+'. Используйте «Открыть» для внешнего плеера.')
    })
    $PreviewSeek.Add_PreviewMouseLeftButtonDown({$script:StudioSeeking=$true})
    $PreviewSeek.Add_PreviewMouseLeftButtonUp({if($script:StudioSeeking){$Preview.Position=[TimeSpan]::FromSeconds($PreviewSeek.Value);$script:StudioSeeking=$false}})
    $PreviewSeek.Add_ValueChanged({if(-not $script:StudioPreviewUpdating -and -not $script:StudioSeeking -and $PreviewSeek.IsEnabled){$Preview.Position=[TimeSpan]::FromSeconds($PreviewSeek.Value)}})
    $script:StudioUiTimer=[Windows.Threading.DispatcherTimer]::new();$StudioUiTimer.Interval=[TimeSpan]::FromMilliseconds(500)
    $StudioUiTimer.Add_Tick({
        if($PreviewSeek.IsEnabled -and -not $script:StudioSeeking){
            $script:StudioPreviewUpdating=$true
            $PreviewSeek.Value=$Preview.Position.TotalSeconds
            $PreviewTime.Text=(Format-Time $Preview.Position.TotalSeconds)+' / '+(Format-Time $PreviewSeek.Maximum)
            $script:StudioPreviewUpdating=$false
        }
    })
    $Window.Add_Loaded({$StudioUiTimer.Start()})
    $Window.Add_Closed({$StudioUiTimer.Stop()})
    $Window.Add_SizeChanged({if($script:StudioUiReady -and $PreviewPane.Visibility-eq'Visible'){Set-StudioReviewPane $true}})
    # Fit the usable desktop at its current DPI, including taskbar and title bar.
    $Area=[Windows.SystemParameters]::WorkArea
    $Window.Width=[Math]::Min($Window.Width,$Area.Width-32)
    $Window.Height=[Math]::Min($Window.Height,$Area.Height-32)
    Initialize-StudioSimple
    Build-StudioSearchIndex
    Update-StudioNavigation;Update-StudioSourceSummary;Update-StudioInlineHelp
}

function Update-StudioNavigation {
    if(-not $script:StudioUiReady){return}
    $Mode=Get-WorkspaceMode
    $NavKey=$Mode+':'+[bool]$script:StudioSimpleModes[$Mode]
    if($script:StudioActiveNavKey -ne $NavKey){
        Update-StudioSimpleControls
        $script:StudioNavigating=$true
        $SectionNav.Items.Clear()
        foreach($Key in @(Get-StudioVisiblePages)){
            $Item=[Windows.Controls.ListBoxItem]::new();$Item.Content=$script:StudioSections[$Key][0];$Item.Tag=$Key
            [void]$SectionNav.Items.Add($Item)
        }
        $script:StudioActiveMode=$Mode;$script:StudioActiveNavKey=$NavKey;$script:StudioNavigating=$false
        $Page=if($script:StudioPageMemory.ContainsKey($Mode)){$script:StudioPageMemory[$Mode]}else{'Source'}
        if($Page -notin @(Get-StudioVisiblePages)){$Page='Simple'}
        Show-StudioSection $Page
    }
    $WorkspaceTitle.Text=switch($Mode){Realtime{'Реалтайм'}Recording{'Запись видео'}VR{'Studio VR'}IW3{'IW3 / 3D'}}
    $RunButton.Content=if($Mode-eq'Realtime'){'Начать просмотр'}elseif($Mode-in @('VR','IW3')){'Создать 3D-видео'}else{'Начать запись'}
    # Recording-only options are absent in realtime, rather than a wall of grey controls.
    $CodecCombo.Parent.Visibility=if($Mode-eq'Realtime'){'Collapsed'}else{'Visible'}
    foreach($Control in @($QualitySlider,$QualityValue.Parent,$KeepTempCheck,$ComparisonCheck,$LivePreviewCheck)){$Control.Visibility=if($Mode-eq'Realtime'){'Collapsed'}else{'Visible'}}
    $FramesBox.Parent.Visibility=if($Mode-eq'Realtime'){'Collapsed'}else{'Visible'}
    $FullVideoCheck.Visibility=if($Mode-eq'Realtime'){'Collapsed'}else{'Visible'}
    # The realtime motion card is separate from the recording override card.
    $MotionCard=$GuideWidthSlider
    while($MotionCard -and $MotionCard -isnot [Windows.Controls.GroupBox]){$MotionCard=$MotionCard.Parent}
    if($MotionCard){$MotionCard.Visibility=if($Mode-eq'Realtime'){'Visible'}else{'Collapsed'}}
    $QuickGroup.Visibility=if($Mode-eq'Realtime' -and -not $script:StudioSimpleModes[$Mode]){'Visible'}else{'Collapsed'}
    Update-StudioSearch
    Update-StudioSourceSummary
}

function Show-StudioSection([string]$Key) {
    if(-not $script:StudioUiReady -or $Key -notin @(Get-StudioVisiblePages)){return}
    $script:StudioScrollMemory[$script:StudioActivePage]=$SettingsScroll.VerticalOffset
    foreach($Entry in $script:StudioPages.GetEnumerator()){$Entry.Value.Visibility=if($Entry.Key-eq$Key){'Visible'}else{'Collapsed'}}
    $script:StudioActivePage=$Key;$script:StudioPageMemory[(Get-WorkspaceMode)]=$Key
    $WorkspaceSubtitle.Text=$script:StudioSections[$Key][1]
    $script:StudioNavigating=$true
    foreach($Item in $SectionNav.Items){if($Item.Tag-eq$Key){$SectionNav.SelectedItem=$Item;break}}
    $script:StudioNavigating=$false
    $Offset=if($script:StudioScrollMemory.ContainsKey($Key)){$script:StudioScrollMemory[$Key]}else{0}
    $SettingsScroll.ScrollToVerticalOffset($Offset)
}

function Set-StudioReviewPane([bool]$Visible) {
    # At small desktop sizes use a full-width review pane, never squeeze controls.
    $Compact=$Visible -and $Window.ActualWidth -gt 0 -and $Window.ActualWidth -lt 1260
    $PreviewPane.Visibility=if($Visible){'Visible'}else{'Collapsed'}
    $PreviewSplitter.Visibility=if($Visible -and -not $Compact){'Visible'}else{'Collapsed'}
    $SettingsColumn.MinWidth=if($Compact){0}else{550}
    $SettingsColumn.Width=if($Compact){[Windows.GridLength]::new(0)}else{[Windows.GridLength]::new(1,[Windows.GridUnitType]::Star)}
    $PreviewGapColumn.Width=[Windows.GridLength]::new($(if($Visible -and -not $Compact){14}else{0}))
    $PreviewColumn.Width=if($Compact){[Windows.GridLength]::new(1,[Windows.GridUnitType]::Star)}else{[Windows.GridLength]::new($(if($Visible){360}else{0}))}
    $PreviewPaneButton.Content=if($Visible){'Скрыть просмотр'}else{'Просмотр'}
    if(-not $Visible -and $script:IsPlaying){$Preview.Pause();$script:IsPlaying=$false}
}

function Update-StudioSourceSummary {
    if(-not $script:StudioUiReady){return}
    $Value=$InputBox.Text.Trim()
    $SourceSummary.Text=if(-not $Value){'Добавьте видео или ссылку, чтобы начать'}elseif($Value -match '^https?://'){$Value}else{[IO.Path]::GetFileName($Value)}
    if($script:SourceInfo -and $script:SourceInfo.input-eq$Value){$SourceSummary.Text+='   ·   '+$script:SourceInfo.width+' × '+$script:SourceInfo.height+'   ·   '+('{0:0.##} FPS' -f $script:SourceInfo.fps)}
    $SourceSummary.ToolTip=$Value
}

function Get-StudioLogicalChildren($Node) {
    if($Node -is [Windows.DependencyObject]){
        foreach($Child in [Windows.LogicalTreeHelper]::GetChildren($Node)){
            if($Child -is [Windows.DependencyObject]){$Child;Get-StudioLogicalChildren $Child}
        }
    }
}

function Build-StudioSearchIndex {
    $script:StudioSearchIndex.Clear();$script:StudioHelpNodes.Clear()
    foreach($Page in $script:StudioPages.GetEnumerator()){
        foreach($Control in @(Get-StudioLogicalChildren $Page.Value)){
            if($Control -is [Windows.Controls.TextBlock] -and ($Control.Style -eq $Window.Resources['SectionHelp'] -or $Control.Style -eq $Window.Resources['FineHelp'])){[void]$script:StudioHelpNodes.Add($Control)}
            if($Control -isnot [Windows.Controls.ComboBox] -and $Control -isnot [Windows.Controls.Slider] -and $Control -isnot [Windows.Controls.CheckBox] -and $Control -isnot [Windows.Controls.TextBox]){continue}
            if($Control.Name -in @('HardwareCombo','ExpertCheck','RealtimeFpsCombo')){continue}
            $Label=[Windows.Automation.AutomationProperties]::GetName($Control)
            if(-not $Label -and $Control -is [Windows.Controls.CheckBox]){$Label=[string]$Control.Content}
            if(-not $Label -and $Control.Parent -is [Windows.Controls.Panel]){
                $Siblings=$Control.Parent.Children;$Position=$Siblings.IndexOf($Control)
                if($Position -gt 0){
                    $Previous=$Siblings[$Position-1]
                    if($Previous -is [Windows.Controls.TextBlock]){$Label=$Previous.Text}
                    elseif($Previous -is [Windows.Controls.Grid]){$Text=@($Previous.Children|Where-Object {$_ -is [Windows.Controls.TextBlock]})|Select-Object -First 1;if($Text){$Label=$Text.Text}}
                }
            }
            if(-not $Label){$Label=[string]$Control.Name}
            if(-not $Label){continue}
            [Windows.Automation.AutomationProperties]::SetName($Control,$Label)
            $Help=Get-StudioControlHelp $Control
            if($Help){[Windows.Automation.AutomationProperties]::SetHelpText($Control,$Help)}
            [void]$script:StudioSearchIndex.Add([pscustomobject]@{Page=$Page.Key;Label=$Label;Control=$Control;Text=($Label+' '+$Help+' '+$Control.Name)})
        }
    }
    foreach($Help in $Iw3HelpBlocks.Values){[void]$script:StudioHelpNodes.Add($Help)}
}

function Update-StudioSearch {
    if(-not $script:StudioUiReady){return}
    $Query=$SettingsSearch.Text.Trim();$SearchResults.Items.Clear()
    $SearchWatermark.Visibility=if($Query){'Collapsed'}else{'Visible'}
    $SearchResultsPane.Visibility=if($Query){'Visible'}else{'Collapsed'}
    if(-not $Query){return}
    $Allowed=@(Get-StudioVisiblePages)
    $Matches=@($script:StudioSearchIndex|Where-Object {$_.Page -in $Allowed -and $_.Text.IndexOf($Query,[StringComparison]::OrdinalIgnoreCase)-ge 0})
    foreach($Match in ($Matches|Select-Object -First 20)){
        $Item=[Windows.Controls.ListBoxItem]::new();$Item.Content=$Match.Label+'  ·  '+$script:StudioSections[$Match.Page][0];$Item.Tag=$Match
        [void]$SearchResults.Items.Add($Item)
    }
    $SearchHint.Text=if($Matches.Count){'Найдено: '+$Matches.Count+' · Enter — перейти к параметру'}else{'Ничего не найдено в этом режиме. Попробуйте «глубина», «буфер» или «DLSS».'}
}

function Open-StudioSearchResult($Item) {
    $Match=$Item.Tag;if(-not $Match){return}
    $SettingsSearch.Clear();Show-StudioSection $Match.Page
    $Node=$Match.Control
    while($Node -and $Node -ne $Window){
        if($Node -is [Windows.Controls.Expander]){$Node.IsExpanded=$true}
        if($Node -is [Windows.Controls.TabItem]){$Node.IsSelected=$true}
        $Node=[Windows.LogicalTreeHelper]::GetParent($Node)
    }
    $Window.UpdateLayout();$Match.Control.BringIntoView();$Match.Control.Focus()|Out-Null
    $ContextHelpText.Text=Get-StudioControlHelp $Match.Control
}

function Get-StudioControlHelp($Control) {
    if($Control.ToolTip -is [Windows.Controls.ToolTip]){return [string]$Control.ToolTip.Content}
    return [string]$Control.ToolTip
}

function Update-StudioInlineHelp {
    $Show=[bool]$InlineHelpCheck.IsChecked
    foreach($Control in $script:StudioHelpNodes){$Control.Visibility=if($Show){'Visible'}else{'Collapsed'}}
    $HelpCard.Visibility=if($Show){'Visible'}else{'Collapsed'}
}

# Simple view is presentation state, not a processing preset. Only the Apply
# button changes the pipeline; the mirrored fields use the existing handlers.
function Get-StudioVisiblePages {
    $Mode=Get-WorkspaceMode
    if($script:StudioSimpleModes -and $script:StudioSimpleModes[$Mode]){return @('Source','Simple')}
    return $script:StudioModePages[$Mode]
}
function Connect-StudioSimpleField($Target,$Source,[string]$Property) {
    [Windows.Data.BindingOperations]::ClearAllBindings($Target)
    if($Target -is [Windows.Controls.ComboBox]){
        $Target.Items.Clear()
        foreach($Item in $Source.Items){
            $Copy=[Windows.Controls.ComboBoxItem]::new();$Copy.Content=$Item.Content;$Copy.Tag=$Item.Tag
            [void]$Target.Items.Add($Copy)
        }
    }elseif($Target -is [Windows.Controls.Slider]){
        $Target.Minimum=$Source.Minimum;$Target.Maximum=$Source.Maximum
        $Target.TickFrequency=$Source.TickFrequency;$Target.IsSnapToTickEnabled=$Source.IsSnapToTickEnabled
    }
    $Binding=[Windows.Data.Binding]::new($Property);$Binding.Source=$Source
    $Binding.Mode='TwoWay';$Binding.UpdateSourceTrigger='PropertyChanged'
    $DependencyProperty=if($Property-eq'SelectedIndex'){[Windows.Controls.Primitives.Selector]::SelectedIndexProperty}else{[Windows.Controls.Primitives.RangeBase]::ValueProperty}
    [void]$Target.SetBinding($DependencyProperty,$Binding)
    $Enabled=[Windows.Data.Binding]::new('IsEnabled');$Enabled.Source=$Source;$Enabled.Mode='OneWay'
    [void]$Target.SetBinding([Windows.UIElement]::IsEnabledProperty,$Enabled)
    $Target.ToolTip=$Source.ToolTip
}
function Initialize-StudioSimple {
    foreach($Name in @('SimpleModeCheck','SimpleProfileCombo','ApplySimpleProfile','SimpleProfileDescription','SimpleProfileStatus','SimpleResolutionCombo','SimpleCodecPanel','SimpleCodecCombo','SimplePlayerPanel','SimpleFpsCombo','SimpleFrameGenCombo','SimpleBufferSlider','SimpleBufferValue','SimpleStereoPanel','SimpleLayoutCombo','SimpleStereoSlider','SimpleStereoValue','SimpleStereoLabel','SimpleDlssCombo','SimpleDetailsButton')){
        Set-Variable -Scope Script -Name $Name -Value $Window.FindName($Name)
    }
    $script:StudioSimpleModes=@{};$script:StudioSimpleChoices=@{};$script:StudioSimpleUpdating=$false
    foreach($Mode in @('Realtime','Recording','VR','IW3')){$StudioSimpleModes[$Mode]=$false;$StudioSimpleChoices[$Mode]='Medium'}
    $SimpleModeCheck.Add_Click({
        if($script:StudioSimpleUpdating){return}
        $script:StudioSimpleModes[(Get-WorkspaceMode)]=[bool]$SimpleModeCheck.IsChecked
        Update-StudioNavigation
    })
    $SimpleProfileCombo.Add_SelectionChanged({
        if($script:StudioSimpleUpdating){return}
        $script:StudioSimpleChoices[(Get-WorkspaceMode)]=Combo-Tag $SimpleProfileCombo
        Update-StudioSimpleDescription
    })
    $ApplySimpleProfile.Add_Click({
        try{Apply-StudioGlobalProfile (Combo-Tag $SimpleProfileCombo)}
        catch{$SimpleProfileStatus.Text='Профиль не применён: '+$_.Exception.Message}
    })
    $SimpleDetailsButton.Add_Click({
        $script:StudioSimpleModes[(Get-WorkspaceMode)]=$false;Update-StudioNavigation
        Show-StudioSection $(switch(Get-WorkspaceMode){Realtime{'Player'}Recording{'Output'}VR{'Depth'}IW3{'IW3'}})
    })
    $SimpleBufferSlider.Add_ValueChanged({$SimpleBufferValue.Text=([int]$SimpleBufferSlider.Value).ToString()+' сек'})
    $SimpleStereoSlider.Add_ValueChanged({$SimpleStereoValue.Text=$SimpleStereoSlider.Value.ToString('0.00',$Invariant)})
}
function Update-StudioSimpleControls {
    if(-not $SimpleModeCheck){return}
    $Mode=Get-WorkspaceMode;$script:StudioSimpleUpdating=$true
    try{
        $SimpleModeCheck.IsChecked=[bool]$StudioSimpleModes[$Mode]
        Select-StringTag $SimpleProfileCombo $StudioSimpleChoices[$Mode]
        Connect-StudioSimpleField $SimpleResolutionCombo $ModeCombo 'SelectedIndex'
        Connect-StudioSimpleField $SimpleCodecCombo $CodecCombo 'SelectedIndex'
        $SimpleCodecPanel.Visibility=if($Mode-eq'Realtime'){'Collapsed'}else{'Visible'}
        $SimplePlayerPanel.Visibility=if($Mode-eq'Realtime'){'Visible'}else{'Collapsed'}
        Connect-StudioSimpleField $SimpleFpsCombo $RealtimeTargetFpsCombo 'SelectedIndex'
        Connect-StudioSimpleField $SimpleFrameGenCombo $FrameGenerationCombo 'SelectedIndex'
        Connect-StudioSimpleField $SimpleBufferSlider $RealtimeBufferSlider 'Value'
        $SimpleStereoPanel.Visibility=if($Mode-in @('VR','IW3')){'Visible'}else{'Collapsed'}
        if($Mode-in @('VR','IW3')){
            $IsIw3=$Mode-eq'IW3'
            Connect-StudioSimpleField $SimpleLayoutCombo $(if($IsIw3){$Iw3Controls['layout']}else{$VrLayoutCombo}) 'SelectedIndex'
            Connect-StudioSimpleField $SimpleStereoSlider $(if($IsIw3){$Iw3Controls['divergence']}else{$VREyeSlider}) 'Value'
            Connect-StudioSimpleField $SimpleDlssCombo $(if($IsIw3){$Iw3Controls['dlss_mode']}else{$VRDLSSModeCombo}) 'SelectedIndex'
            $SimpleStereoLabel.Text=if($IsIw3){'Сила 3D · параллакс, %'}else{'Сила 3D · масштаб глубины'}
            $SimpleStereoValue.Text=$SimpleStereoSlider.Value.ToString('0.00',$Invariant)
        }else{
            # Detach the old mode before hidden mirrors can write into IW3/VR.
            foreach($Field in @($SimpleLayoutCombo,$SimpleStereoSlider,$SimpleDlssCombo)){[Windows.Data.BindingOperations]::ClearAllBindings($Field)}
        }
    }finally{$script:StudioSimpleUpdating=$false}
    Update-StudioSimpleDescription
}
function Update-StudioSimpleDescription {
    $Tier=Combo-Tag $SimpleProfileCombo;$Mode=Get-WorkspaceMode
    $Description=switch($Tier){
        UltraFast{'Минимум затрат на служебные карты. Для проверки видео и быстрого просмотра.'}
        Fast{'Лёгкая глубина и умеренная точность движения. Приоритет скорости.'}
        Medium{'Сбалансированная глубина и движение. Рекомендуемая отправная точка.'}
        Heavy{'Более точные карты и восстановление. Выше нагрузка на GPU и память.'}
        Maximum{'Самые точные настройки этого набора. Существенно медленнее; постоянный realtime FPS не гарантируется.'}
    }
    $Scope=switch($Mode){
        Realtime{'Настраивает движение, глубину, внутренний DLSS и буфер. Генерация кадров и её цель остаются вашими.'}
        Recording{'Настраивает аппаратный профиль, служебные карты, внутренний DLSS и качество кодирования.'}
        VR{'Настраивает общую глубину, стерео, фон и DLSS 5. RowFlow используется, если установлен.'}
        IW3{'Настраивает RowFlow v3, модель глубины, EMA, границы и использование памяти. DLSS остаётся отдельной опцией.'}
    }
    $SimpleProfileDescription.Text=$Description+' '+$Scope+' Разрешение, диапазон и пути не меняются. Внешний апскейлер выключается; его можно включить в подробных настройках.'
    $SimpleProfileStatus.Text='Выберите профиль и нажмите «Применить». Пока используются текущие настройки; само переключение интерфейса их не меняет.'
}
function Test-StudioSimpleDa3([string]$Id) {
    $Model=@($Iw3Da3Catalog.models|Where-Object id -eq $Id)
    if($Model.Count-ne 1){return $false}
    $M=$Model[0];$Path=Join-Path $Root $M.path
    $Source=Join-Path $Root $Iw3Da3Catalog.sources.($M.source).path
    if(-not(Test-Path -LiteralPath $Path -PathType Leaf) -or -not(Test-Path -LiteralPath (Join-Path $Source 'src/depth_anything_3/api.py') -PathType Leaf)){return $false}
    # Cheap availability only, not an integrity claim. The normal worker still
    # verifies installation metadata; no hashing GB weights on the UI thread.
    return (Get-Item -LiteralPath $Path).Length -eq [long]$M.bytes
}
function Get-StudioSimpleDepth([string]$Tier,[bool]$Stereo) {
    $Light=$Tier-in @('UltraFast','Fast')
    $Candidates=if($Stereo){
        if($Light){@('Studio_DA3_Small','Studio_DA3_Base','Any_V3_Mono')}
        elseif($Tier-eq'Medium'){@('Studio_DA3_Base','Any_V3_Mono','Studio_DA3_Small')}
        else{@('Any_V3_Mono','Studio_DA3_Large_11','Studio_DA3_Base','Studio_DA3_Small')}
    }elseif($Light){@('DA2Small','DA3Small','VideoDepthSmall')}
    elseif($Tier-eq'Medium'){@('DA3Small','VideoDepthSmall','DA2Small')}
    else{@('DA3Large','DA3Base','VideoDepthSmall','DA3Small','DA2Small')}
    foreach($Id in $Candidates){
        $Ready=if($Stereo){Test-StudioSimpleDa3 $Id}else{(Get-DepthModelStatus -Root $Root -Profile $Id).Ready}
        if($Ready){return [pscustomobject]@{Id=$Id;Ready=$true;Preferred=$Candidates[0]}}
    }
    return [pscustomobject]@{Id=$(if($Stereo){'Selected'}else{'DA2Small'});Ready=$false;Preferred=$Candidates[0]}
}
function Apply-StudioGlobalProfile([string]$Tier) {
    if($Tier -notin @('UltraFast','Fast','Medium','Heavy','Maximum')){throw 'Неизвестный профиль.'}
    if($script:Process){throw 'Сначала остановите обработку.'}
    $Mode=Get-WorkspaceMode;$Index=@('UltraFast','Fast','Medium','Heavy','Maximum').IndexOf($Tier)
    $Depth=Get-StudioSimpleDepth $Tier $false
    $Notes=[Collections.Generic.List[string]]::new()
    $Layout=Combo-Tag $VrLayoutCombo
    Select-StringTag $HardwareCombo 'Auto'
    Select-StringTag $PerformanceCombo $Tier
    Select-StringTag $RenderPresetCombo $(if($Index-ge 3){'Native'}else{'Auto'})
    Select-StringTag $DepthModelCombo $Depth.Id
    Select-StringTag $UpscalerCombo 'None'
    Apply-Settings $BuiltIn['Balanced · рекомендовано']
    # Keep the neutral NR appearance; quality does not mean stronger repainting.
    $PresetBox.SelectedItem='Balanced · рекомендовано'
    if($Mode-ne'IW3'){
        if(-not $Depth.Ready){$Notes.Add('Служебная DA2Small отсутствует: установите модель в подробных настройках.')}
        elseif($Depth.Id-ne$Depth.Preferred){$Notes.Add('Вместо '+$Depth.Preferred+' выбрана установленная '+$Depth.Id+'.')}
    }
    $QualitySlider.Value=@(23,21,18,16,14)[$Index]
    $RecordFineGuideCheck.IsChecked=$false
    if($Mode-eq'Realtime'){
        Select-StringTag $RealtimeQualityCombo $Tier;Apply-RealtimeProfile $Tier
        $RealtimeBufferSlider.Value=@(5,5,8,10,15)[$Index]
        $Notes.Add('Глубина: '+$Depth.Id+'; движение: '+(Combo-Tag $GuideMotionBackendCombo)+', guide '+[int]$GuideWidthSlider.Value+' px; буфер '+[int]$RealtimeBufferSlider.Value+' сек.')
    }elseif($Mode-eq'VR'){
        Select-StringTag $VRQualityPresetCombo $(if($Index-le 1){'Fast'}elseif($Index-eq 4){'Maximum'}else{'Cinematic'})
        Apply-VrProfile
        # Existing presets choose a model speculatively; resolve installed ones.
        Select-StringTag $DepthModelCombo $Depth.Id
        Select-StringTag $VrLayoutCombo $Layout
        Select-StringTag $VRQualityPipelineCombo 'Native'
        Select-StringTag $VRGeometryModeCombo 'IW3'
        Select-StringTag $VRStereoMethodCombo $(if($script:RowFlowReady){'RowFlowV3'}else{'GAPW'})
        $StereoDepth=Get-StudioSimpleDepth $Tier $true
        Select-StringTag $VRDepthModelCombo $(if($script:RowFlowReady -and $StereoDepth.Ready){$StereoDepth.Id}else{'Selected'})
        Select-StringTag $VRDepthResolutionCombo (@('392','518','518','644','644')[$Index])
        if($Index-eq 0){Select-StringTag $VRGenerativeBackendCombo 'Off'}
        $Notes.Add('Стерео: '+(Combo-Tag $VRStereoMethodCombo)+'; глубина: '+(Combo-Tag $VRDepthModelCombo)+' / '+(Combo-Tag $VRDepthResolutionCombo)+'; фон: '+(Combo-Tag $VRGenerativeBackendCombo)+'.')
        if(-not $script:RowFlowReady){$Notes.Add('RowFlow не установлен: используется GAPW. Для качества RowFlow установите компоненты IW3.')}
        if(-not $StereoDepth.Ready){$Notes.Add('DA3 для стерео не найдена: используется общая модель '+$Depth.Id+'.')}
        elseif($StereoDepth.Id-ne$StereoDepth.Preferred){$Notes.Add('Вместо '+$StereoDepth.Preferred+' доступна '+$StereoDepth.Id+'.')}
    }elseif($Mode-eq'IW3'){
        $Previous=Get-Iw3Settings;$StereoDepth=Get-StudioSimpleDepth $Tier $true
        $Settings=[ordered]@{
            method='row_flow_v3';depth_model=$(if($StereoDepth.Ready){$StereoDepth.Id}else{'Any_V2_S'})
            resolution=@(392,392,518,644,812)[$Index];limit_resolution=$true
            ema_normalize=$true;ema_decay=0.75;ema_buffer=30;scene_detect=$true
            batch_size=1;da3_microbatch=1;disable_amp=$false;max_workers='0'
            layout=$Previous.layout;divergence=$Previous.divergence;convergence=$Previous.convergence
            dlss_mode=$Previous.dlss_mode;target_fps=$Previous.target_fps
        }
        Set-Iw3Settings $Settings;Update-Iw3Ui
        $Notes.Add('RowFlow v3; глубина: '+$Settings.depth_model+' / '+$Settings.resolution+'; EMA, AMP, микробатч 1. Качество записи CQ '+[int]$QualitySlider.Value+'.')
        if(-not $script:RowFlowReady){$Notes.Add('Компоненты RowFlow отсутствуют: установите IW3 перед запуском.')}
        if(-not $StereoDepth.Ready){$Notes.Add('DA3 не найдена: выбран Any_V2_S. Его наличие проверяется штатным IW3 при запуске.')}
        elseif($StereoDepth.Id-ne$StereoDepth.Preferred){$Notes.Add('Вместо '+$StereoDepth.Preferred+' доступна '+$StereoDepth.Id+'.')}
        if($Settings.dlss_mode-ne'Off' -and -not $Depth.Ready){$Notes.Add('Для DLSS требуется установка служебной модели '+$Depth.Id+'.')}
    }else{
        $Notes.Add('Глубина: '+$Depth.Id+'; аппаратный профиль: '+$Tier+'; кодирование CQ '+[int]$QualitySlider.Value+'.')
    }
    Refresh-Labels;Update-ProfileUi;Update-VrUi;Update-Estimate
    $SimpleProfileStatus.Text='Применено: '+[string]$SimpleProfileCombo.SelectedItem.Content+'. '+($Notes -join ' ')+' Модели не скачивались. Дальнейшие ручные изменения имеют приоритет.'
}
