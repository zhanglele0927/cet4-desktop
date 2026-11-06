param([switch]$Check)
$ErrorActionPreference='Stop'
$checkOutputRoot='D:\codex\work\cet4-widget-check'
if($Check){[void][IO.Directory]::CreateDirectory($checkOutputRoot)}
Add-Type -AssemblyName PresentationFramework
if(-not $Check){
 $script:instance=New-Object Threading.Mutex($false,'Local\LeleCET4WidgetV2')
 if(-not $script:instance.WaitOne(0)) {[void][Windows.MessageBox]::Show('背词小窗已经打开，请查看桌面或任务栏。','四级背词');exit}
}
. (Join-Path $PSScriptRoot 'Learning.ps1')
$statePath=Join-Path $PSScriptRoot 'learning-v2.json'
function Convert-Map($obj){
 if($null -eq $obj){return $null}
 if($obj -is [System.Management.Automation.PSCustomObject]){$h=@{};foreach($p in $obj.PSObject.Properties){$h[$p.Name]=Convert-Map $p.Value};return $h}
 if($obj -is [array]){return ,@($obj | ForEach-Object {Convert-Map $_})}
 return $obj
}
$script:data=New-LearningState
$script:libraryDrawers=@{}
$phonetics=@{}
if(Test-Path (Join-Path $PSScriptRoot 'phonetics.json')){
 $phonetics=Convert-Map (Get-Content (Join-Path $PSScriptRoot 'phonetics.json') -Raw -Encoding UTF8 | ConvertFrom-Json)
}
if(Test-Path $statePath){try{$script:data=Convert-Map (Get-Content $statePath -Raw -Encoding UTF8 | ConvertFrom-Json)}catch{Copy-Item $statePath "$statePath.recovery-$(Get-Date -Format yyyyMMddHHmmss)"}}
$dict=@{};$ordered=New-Object System.Collections.ArrayList
if(Test-Path (Join-Path $PSScriptRoot 'cet4-source.json')){
 foreach($w in (Get-Content (Join-Path $PSScriptRoot 'cet4-source.json') -Raw -Encoding UTF8 | ConvertFrom-Json)){
  if($w.word -notmatch '^[a-zA-Z][a-zA-Z-]*$' -or $dict.ContainsKey($w.word)){continue}
  $dict[$w.word]=[pscustomobject]@{Word=$w.word;Meaning=(($w.translations | ForEach-Object {"$($_.type). $($_.translation)"}) -join '；');Example=(($w.phrases | Select-Object -First 2 | ForEach-Object {"$($_.phrase)  $($_.translation)"}) -join "`n")}
 }
}
foreach($line in Get-Content (Join-Path $PSScriptRoot 'words.txt') -Encoding UTF8){$p=$line -split '\|';$w=[pscustomobject]@{Word=$p[0];Meaning=$p[1];Example=$p[2]};if($dict.ContainsKey($w.Word)){$w.Meaning=$dict[$w.Word].Meaning};$dict[$w.Word]=$w;[void]$ordered.Add($w)}
$seen=@{};foreach($w in $ordered){$seen[$w.Word]=$true}
foreach($key in @($dict.Keys | Sort-Object)){if(-not $seen.ContainsKey($key)){[void]$ordered.Add($dict[$key])}}
$words=@($ordered);$script:date=Get-StudyDate
$frequency=@{};$basicWords=@{};$script:orderVersion=''
$frequencyPath=Join-Path $PSScriptRoot 'frequency-order.json'
if(-not (Test-Path $frequencyPath)){throw '缺少词频排序文件 frequency-order.json，请恢复该文件后再启动。'}
$ranking=Convert-Map (Get-Content $frequencyPath -Raw -Encoding UTF8 | ConvertFrom-Json)
$ranked=New-Object System.Collections.ArrayList;$rankSeen=@{}
foreach($item in $ranking.words){
 if($dict.ContainsKey($item.word) -and -not $rankSeen.ContainsKey($item.word)){
  [void]$ranked.Add($dict[$item.word]);$rankSeen[$item.word]=$true;$frequency[$item.word]=$item.count
  if($item.basic){$basicWords[$item.word]=$true}
 }
}
if($ranked.Count -ne $words.Count){throw '词频排序文件不完整，请恢复 frequency-order.json。'}
$words=@($ranked);$script:orderVersion=$ranking.version
$script:priorityBatchId='';$script:priorityKeys=@()
$priorityPath=Join-Path $PSScriptRoot 'priority-words.json'
if(Test-Path $priorityPath){
 $priorityConfig=Convert-Map (Get-Content $priorityPath -Raw -Encoding UTF8 | ConvertFrom-Json)
 $script:priorityBatchId=$priorityConfig.batchId
 foreach($item in $priorityConfig.items){
  $key=[string]$item.word
  if(-not $key -or $script:priorityKeys -contains $key){continue}
  $script:priorityKeys+=@($key)
  if($dict.ContainsKey($key)){
   $entry=$dict[$key]
   if($item.meaning -and $entry.Meaning -notlike "*$($item.meaning)*"){$entry.Meaning="$($item.meaning)；$($entry.Meaning)"}
   if($item.example){$entry.Example=$item.example}
  }else{
   $dict[$key]=[pscustomobject]@{Word=$key;Meaning=$item.meaning;Example=$item.example}
  }
  if($item.ipa){$phonetics[$key.ToLowerInvariant()]=@{ipa=$item.ipa;accent=$item.accent}}
  elseif(-not $phonetics.ContainsKey($key.ToLowerInvariant())){$phonetics[$key.ToLowerInvariant()]=@{ipa='';accent=''}}
  $basicWords.Remove($key)
 }
 $priorityEntries=@($script:priorityKeys | ForEach-Object {$dict[$_]})
 $words=@($priorityEntries)+@($words | Where-Object {$script:priorityKeys -notcontains $_.Word})
 Initialize-PriorityBatch $script:data $script:priorityBatchId $script:priorityKeys
 $script:orderVersion+='-'+$script:priorityBatchId
 if($priorityConfig.extension){
  $batch=$script:data.priorityBatches[$script:priorityBatchId]
  $original=@{}
  foreach($key in $priorityConfig.extension.originalKeys){$original[$key]=$true}
  $completed=@{}
  foreach($key in $batch.completed){$completed[$key]=$true}
  foreach($key in $script:priorityKeys){
   if(-not $original.ContainsKey($key) -and $script:data.records.ContainsKey($key) -and -not $completed.ContainsKey($key)){
    $batch.completed+=@($key)
   }
  }
  $batch.keys=@($script:priorityKeys)
  $script:orderVersion+='-'+$priorityConfig.extension.id
 }
}
$studyWords=@($words | Where-Object {-not $basicWords.ContainsKey($_.Word)})
if(-not (Test-Path $statePath) -and (Test-Path (Join-Path $PSScriptRoot 'progress.json'))){
 $old=Get-Content (Join-Path $PSScriptRoot 'progress.json') -Raw -Encoding UTF8 | ConvertFrom-Json
 foreach($key in @($old.known)){if($key){Set-WordRating $script:data $key $true $script:date 'review'}}
 foreach($key in @($old.wrong)){if($key){Set-WordRating $script:data $key $false $script:date 'review'}}
}
Repair-VocabularyKeys $script:data
Initialize-Day $script:data $studyWords $script:date $script:orderVersion @(Get-PendingPriorityKeys $script:data $script:priorityBatchId)
$script:mode='new';$script:queue=@();$script:pos=0;$script:current=$null;$script:answer=$false;$script:wasWrong=$false
[xml]$layout=@'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" Title="四级背词" Width="240" Height="320" MinWidth="220" MinHeight="300" FontSize="10" Background="#101827" Foreground="#EEF2FF" WindowStartupLocation="CenterScreen" ResizeMode="NoResize" WindowStyle="None" Topmost="True">
 <Window.Resources>
  <Style TargetType="Button"><Setter Property="Padding" Value="6,4"/><Setter Property="Margin" Value="0,0,4,4"/><Setter Property="Background" Value="#25334D"/><Setter Property="Foreground" Value="#EEF2FF"/><Setter Property="BorderThickness" Value="0"/><Setter Property="Cursor" Value="Hand"/></Style>
  <Style TargetType="CheckBox"><Setter Property="Margin" Value="0,5,14,5"/><Setter Property="Foreground" Value="#CBD5E1"/></Style>
 </Window.Resources>
 <Border BorderBrush="#5EEAD4" BorderThickness="0,0,0,4"><DockPanel Margin="9,7,9,7">
  <StackPanel DockPanel.Dock="Top">
   <DockPanel Name="DragHandle" Background="Transparent" Cursor="SizeAll" ToolTip="拖动调整位置"><Button Name="SettingsButton" Content="更多 ···" DockPanel.Dock="Right" Padding="8,3" Margin="0"/><TextBlock Name="Stats" Foreground="#A5B4CF" VerticalAlignment="Center" FontSize="10"/></DockPanel>
   <UniformGrid Columns="2" Margin="0,6,0,0"><Button Name="LearnedLibrary" Content="已背词库" ToolTip="所有日期已学习的单词"/><Button Name="PendingLibrary" Content="未背词库" ToolTip="整个词库中尚未学习的单词" Margin="0,0,0,4"/></UniformGrid>
   <ProgressBar Name="DailyBar" Height="3" Maximum="100" Margin="0,10,0,2" Foreground="#5EEAD4"/>
   <Popup Name="Settings" Placement="Bottom" StaysOpen="False" AllowsTransparency="True" PopupAnimation="Fade">
    <Border Background="#182338" BorderBrush="#35435E" BorderThickness="1" CornerRadius="8" Padding="10" Width="260">
     <ScrollViewer MaxHeight="450" VerticalScrollBarVisibility="Auto"><StackPanel>
      <TextBlock Text="学习" FontWeight="Bold" Margin="0,0,0,8"/>
      <WrapPanel><Button Name="NewButton" Content="今日新词"/><Button Name="DueButton" Content="到期复习"/><Button Name="WrongButton" Content="错词本"/></WrapPanel>
      <WrapPanel><Button Name="Next" Content="下一词 →"/><CheckBox Name="Pin" Content="置顶" IsChecked="True"/><CheckBox Name="Auto" Content="轮播" IsEnabled="False" ToolTip="拼写模式下暂停自动轮播"/></WrapPanel>
      <WrapPanel><CheckBox Name="DockHide" Content="贴边自动隐藏" IsChecked="True"/><Button Name="CloseWidget" Content="关闭挂件"/></WrapPanel>
      <TextBlock Text="字号" Margin="0,8,0,0"/><Slider Name="FontSlider" Minimum="16" Maximum="32" Value="20" TickFrequency="2" IsSnapToTickEnabled="True"/>
      <TextBlock Text="不透明度"/><Slider Name="OpacitySlider" Minimum="0.5" Maximum="1" Value="1"/>
      <TextBlock Text="轮播间隔（秒）"/><ComboBox Name="Seconds" SelectedIndex="1"><ComboBoxItem Content="10"/><ComboBoxItem Content="15"/><ComboBoxItem Content="30"/><ComboBoxItem Content="60"/></ComboBox>
      <TextBlock Text="英文与中文释义都正确后回车继续；输入模式暂停轮播。" TextWrapping="Wrap" Foreground="#94A3B8" FontSize="10" Margin="0,8,0,0"/>
      <TextBlock Text="空格：中文显隐　←/→：切词" Foreground="#94A3B8" FontSize="10" Margin="0,6,0,0"/>
      <TextBlock Name="BasicFilterNote" Text="已过滤入门基础词，其余按四级样本词频降序。" Foreground="#94A3B8" FontSize="10" TextWrapping="Wrap" Margin="0,6,0,0"/>
     </StackPanel></ScrollViewer>
    </Border>
   </Popup>
  </StackPanel>
  <StackPanel DockPanel.Dock="Bottom">
   <TextBlock Text="英文 + 一条中文释义，回车继续" Foreground="#8191AC" FontSize="10" Margin="0,5,0,5"/>
   <Grid><Grid.ColumnDefinitions><ColumnDefinition Width="27"/><ColumnDefinition/></Grid.ColumnDefinitions><Grid.RowDefinitions><RowDefinition/><RowDefinition/></Grid.RowDefinitions>
    <TextBlock Text="英文" Foreground="#A5B4CF" VerticalAlignment="Center"/>
    <TextBox Name="EnglishInput" Grid.Column="1" FontSize="12" Padding="5,3" Margin="0,0,0,4" Background="#182338" Foreground="#EEF2FF" CaretBrush="#5EEAD4" BorderBrush="#35435E" BorderThickness="1" SpellCheck.IsEnabled="False" InputMethod.IsInputMethodEnabled="False"/>
    <TextBlock Text="中文" Grid.Row="1" Foreground="#A5B4CF" VerticalAlignment="Center"/>
    <TextBox Name="Spelling" Grid.Row="1" Grid.Column="1" FontSize="12" Padding="5,3" Background="#182338" Foreground="#EEF2FF" CaretBrush="#5EEAD4" BorderBrush="#35435E" BorderThickness="1" SpellCheck.IsEnabled="False" InputMethod.PreferredImeState="On"/>
   </Grid>
   <TextBlock Name="Notice" Foreground="#A5B4CF" TextWrapping="Wrap" Margin="0,3,0,5" FontSize="10"/>
   <Grid><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition/></Grid.ColumnDefinitions><Button Name="Good" Content="认识 →" Background="#11665D"/><Button Name="Bad" Content="不认识" Grid.Column="1" Margin="0,0,0,4"/></Grid>
   <DockPanel Margin="0,0,0,5"><Button Name="Previous" Content="← 上一词" Background="Transparent" Foreground="#A5B4CF" Padding="0,2" Margin="0"/><Button Name="ListButton" Content="今日单词" DockPanel.Dock="Right" HorizontalAlignment="Right" Background="Transparent" Foreground="#A5B4CF" Padding="0,2" Margin="0"/></DockPanel>
   <DockPanel><Button Name="ChineseButton" Content="隐藏中文" Background="Transparent" Foreground="#A5B4CF" Padding="0,2" Margin="0"/></DockPanel>
  </StackPanel>
  <ScrollViewer Name="WordScroll" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" Margin="0,4,0,0"><StackPanel>
   <TextBlock Name="Position" Visibility="Collapsed"/><DockPanel Margin="0,5,0,7"><Button Name="Speak" Content="朗读 ♫" DockPanel.Dock="Right" HorizontalAlignment="Right" Background="Transparent" Foreground="#A5B4CF" Padding="0,2" Margin="8,0,0,0" VerticalAlignment="Top"/><TextBlock Name="Word" FontSize="20" FontWeight="Bold" TextWrapping="Wrap"/></DockPanel>
   <TextBlock Name="Phonetic" FontFamily="Segoe UI" FontSize="13" Foreground="#93C5FD" TextWrapping="Wrap" Margin="0,0,0,7" ToolTip="国际音标；美为美式，英为英式。多种读法并列显示。"/>
   <TextBlock Name="FrequencyInfo" FontSize="10" Foreground="#8191AC" TextWrapping="Wrap" Margin="0,0,0,6" ToolTip="第三方四级样本正文频次，已扣合订本重复；不是下次考试的出现概率。"/>
   <TextBlock Name="Meaning" FontSize="12" TextWrapping="Wrap" Margin="0,0,0,4"/><TextBlock Name="Example" FontSize="10" Foreground="#93C5FD" TextWrapping="Wrap"/>
  </StackPanel></ScrollViewer>
 </DockPanel></Border>
</Window>
'@
$window=[Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $layout))
foreach($name in @('FrequencyInfo','Phonetic','WordScroll','LearnedLibrary','PendingLibrary','SettingsButton','Stats','DailyBar','NewButton','DueButton','WrongButton','ListButton','Notice','Good','Bad','Previous','Next','ChineseButton','Speak','Pin','Auto','Settings','FontSlider','OpacitySlider','Seconds','Position','Word','Meaning','Example','Spelling','EnglishInput','DragHandle','DockHide','CloseWidget')){Set-Variable $name $window.FindName($name)}
function Save-State {
 if($Check){return}
 $s=$script:data.settings;$s.pin=[bool]$Pin.IsChecked;$s.dockHide=[bool]$DockHide.IsChecked;$s.font=$FontSlider.Value;$s.opacity=$window.Opacity;$s.width=$window.Width;$s.height=$window.Height
 if(-not [double]::IsNaN($window.Left)){$s.left=$window.Left;$s.top=$window.Top;if($script:dock -and $DockHide.IsChecked){$s.top=$script:dock.expandedTop}}
 $json=$script:data | ConvertTo-Json -Depth 12;$tmp="$statePath.tmp";[IO.File]::WriteAllText($tmp,$json,(New-Object Text.UTF8Encoding $true));Move-Item -LiteralPath $tmp -Destination $statePath -Force
}
function Check-Day {
 $today=Get-StudyDate
 if($today -ne $script:date){$script:date=$today;Initialize-Day $script:data $studyWords $today $script:orderVersion @(Get-PendingPriorityKeys $script:data $script:priorityBatchId);$script:queue=@();$script:current=$null}
}
function Render-Word {
 $done=@($script:data.completed[$script:date]).Count;$target=@($script:data.plans[$script:date]).Count;$due=@(Get-ReviewKeys $script:data | Where-Object {-not $basicWords.ContainsKey($_)}).Count
 if($script:mode -eq 'new'){$Stats.Text="今日  $done / $target"}else{$label=@{review='复习';wrong='错词'}[$script:mode];$Stats.Text="$label  $([Math]::Min($script:pos+1,$script:queue.Count)) / $($script:queue.Count)"}
 if($script:wasWrong){$Bad.Content='下一个 →'}else{$Bad.Content='不认识'}
 $DailyBar.Maximum=[Math]::Max($target,1);$DailyBar.Value=$done;$DueButton.Content="到期复习 ($due)"
 $Good.IsEnabled=$null -ne $script:current;$Bad.IsEnabled=$Good.IsEnabled;$Speak.IsEnabled=$Good.IsEnabled
 $Spelling.IsEnabled=$Good.IsEnabled
 $EnglishInput.IsEnabled=$Good.IsEnabled
 $Previous.IsEnabled=$script:queue.Count -gt 0 -and $script:pos -gt 0
 if($script:data.settings.chinese){$ChineseButton.Content='隐藏中文'}else{$ChineseButton.Content='显示中文'}
 if($null -eq $script:current){$Word.Text='本组完成';$Phonetic.Text='';$FrequencyInfo.Text='';$Meaning.Text='可以切换到到期复习或错词本。';$Meaning.Visibility='Visible';$Example.Text='';$Position.Text='没有待学习词';return}
 $w=$dict[$script:current];$Word.Text=$w.Word;$WordScroll.ScrollToTop();$Meaning.Text=$w.Meaning;$Example.Text=$w.Example
 $pronunciation=$phonetics[$w.Word.ToLowerInvariant()]
 $Phonetic.Text=if($pronunciation -and $pronunciation.ipa){"$($pronunciation.accent) $($pronunciation.ipa)"}else{'音标暂缺'}
 $count=$frequency[$w.Word]
 $FrequencyInfo.Text=if($null -ne $count){"四级样本正文：$count 次"}else{'补充词：样本未收录'}
 if($script:priorityKeys -contains $w.Word){$FrequencyInfo.Text='近期优先 · 你提供的词表'}
 $label=@{new='今日新词';review='到期复习';wrong='错词本'}[$script:mode];$Position.Text="$label · $($script:pos+1) / $($script:queue.Count)"
 if($script:data.settings.chinese -or $script:answer){$Meaning.Visibility='Visible';$Example.Visibility='Visible'}else{$Meaning.Visibility='Hidden';$Example.Visibility='Hidden'}
}
function Start-Session([string]$mode) {
 Check-Day;$script:mode=$mode;$script:pos=0;$script:answer=$false;$script:wasWrong=$false;$Spelling.Clear();$EnglishInput.Clear()
 if($mode -eq 'new'){$script:queue=@($script:data.plans[$script:date] | Where-Object {-not $basicWords.ContainsKey($_) -and -not ($script:data.records.ContainsKey($_) -and $script:data.records[$_].noReview)});while($script:pos -lt $script:queue.Count -and $script:data.completed[$script:date] -contains $script:queue[$script:pos]){$script:pos++}}
 elseif($mode -eq 'review'){$script:queue=@(Get-ReviewKeys $script:data | Where-Object {-not $basicWords.ContainsKey($_)})}else{$script:queue=@(Get-ReviewKeys $script:data $true | Where-Object {-not $basicWords.ContainsKey($_)})}
 if($script:pos -lt $script:queue.Count){$script:current=$script:queue[$script:pos]}else{$script:current=$null}
 $Settings.IsOpen=$false;$Notice.Text='';Render-Word;Save-State
}
function Move-Word([int]$step,[switch]$SkipSpelling) {
 Check-Day;if(-not $script:queue.Count){Start-Session $script:mode;return}
 if($step -gt 0 -and $script:current -and -not $SkipSpelling -and -not (Test-Spelling)){return}
 $script:pos=[Math]::Max(0,$script:pos+$step);$script:answer=$false;$script:wasWrong=$false;$Notice.Text='';$Spelling.Clear();$EnglishInput.Clear()
 if($script:pos -ge $script:queue.Count){$script:current=$null}else{$script:current=$script:queue[$script:pos]}
 Render-Word
 if($script:current){[void]$EnglishInput.Focus()}
}
function Normalize-Meaning([string]$text) {
 ($text -replace '[^\p{IsCJKUnifiedIdeographs}0-9]','')
}
function Get-MeaningAnswers([string]$key) {
 $meaning=$dict[$key].Meaning -replace '（[^）]*）|\([^)]*\)|\[[^\]]*\]',''
 @(@($meaning -split '[；;，,、/\r\n]')+@($meaning) | ForEach-Object {Normalize-Meaning $_} | Where-Object {$_ -match '\p{IsCJKUnifiedIdeographs}'} | Select-Object -Unique)
}
function Test-Spelling {
 if(-not $script:current -or -not [string]::Equals($EnglishInput.Text.Trim(),$script:current,[StringComparison]::OrdinalIgnoreCase)){
  $Notice.Text='请完整输入正确的英文单词';$EnglishInput.BorderBrush='#F87171';[void]$EnglishInput.Focus();return $false
 }
 $inputMeaning=Normalize-Meaning $Spelling.Text
 if($script:current -and $inputMeaning -and @(Get-MeaningAnswers $script:current) -contains $inputMeaning){return $true}
 $Notice.Text='请输入词库中的一条完整中文释义';$Spelling.BorderBrush='#F87171';[void]$Spelling.Focus();return $false
}
function Submit-Spelling {
 if(-not $script:current){return}
 if(-not (Test-Spelling)){return}
 if($script:wasWrong){Move-Word 1 -SkipSpelling}else{Rate-Word $false -Advance}
}
function Rate-Word([bool]$correct,[switch]$Advance) {
 Check-Day;if($null -eq $script:current){return}
 Set-WordRating $script:data $script:current $correct $script:date $script:mode;Save-State
 if($correct -or $Advance){Move-Word 1 -SkipSpelling}
 else{$script:answer=$true;$script:wasWrong=$true;$Notice.Text='已加入错词本，输入后继续';Render-Word;[void]$Spelling.Focus()}
}
$speech=$null
try{Add-Type -AssemblyName System.Speech;$speech=New-Object System.Speech.Synthesis.SpeechSynthesizer;$voice=$speech.GetInstalledVoices() | Where-Object {$_.VoiceInfo.Culture.Name -like 'en-*'} | Select-Object -First 1;if($voice){$speech.SelectVoice($voice.VoiceInfo.Name)}}catch{}
function Speak-Word {if($speech -and $script:current){$speech.SpeakAsyncCancelAll();[void]$speech.SpeakAsync($script:current)}else{$Notice.Text='系统未提供可用朗读语音。'}}
$NewButton.Add_Click({Start-Session 'new'});$DueButton.Add_Click({Start-Session 'review'});$WrongButton.Add_Click({Start-Session 'wrong'})
$Good.Add_Click({if($script:wasWrong){Move-Word 1 -SkipSpelling}else{Rate-Word $true}});$Bad.Add_Click({if($script:wasWrong){Move-Word 1}else{Rate-Word $false}});$Previous.Add_Click({Move-Word -1});$Next.Add_Click({Move-Word 1})
$Spelling.Add_TextChanged({$Spelling.BorderBrush='#35435E';$Notice.Text=''})
$EnglishInput.Add_TextChanged({$EnglishInput.BorderBrush='#35435E';$Notice.Text=''})
$ChineseButton.Add_Click({$script:data.settings.chinese=-not $script:data.settings.chinese;$script:answer=$false;Render-Word;Save-State})
$Speak.Add_Click({Speak-Word});$Pin.Add_Click({$window.Topmost=[bool]$Pin.IsChecked;Save-State})
$Settings.PlacementTarget=$SettingsButton
$SettingsButton.Add_Click({$Settings.IsOpen=-not $Settings.IsOpen})
$FontSlider.Add_ValueChanged({$Word.FontSize=$FontSlider.Value});$OpacitySlider.Add_ValueChanged({$window.Opacity=$OpacitySlider.Value})
function New-DayListWindow {
 Check-Day;$Settings.IsOpen=$false
 $groups=Get-DayWordLists $script:data $script:date
 $listWindow=New-Object Windows.Window;$listWindow.Title="今日单词 · $($script:date)";$listWindow.Width=380;$listWindow.Height=430;$listWindow.MinWidth=300;$listWindow.MinHeight=300;$listWindow.Owner=$window;$listWindow.WindowStartupLocation='CenterOwner';$listWindow.Background='#101827';$listWindow.Foreground='#EEF2FF'
 $panel=New-Object Windows.Controls.DockPanel;$panel.Margin=16
 $note=New-Object Windows.Controls.TextBlock;$note.Text='已背过含今日新词和复习词；不认识也算已学习。';$note.TextWrapping='Wrap';$note.Foreground='#94A3B8';$note.Margin='0,0,0,12';[Windows.Controls.DockPanel]::SetDock($note,'Top');[void]$panel.Children.Add($note)
 $tabs=New-Object Windows.Controls.TabControl;$tabs.Background='#101827';$tabs.BorderBrush='#35435E'
 foreach($group in @(@{Title='已背过';Keys=@($groups.Learned)},@{Title='还要背';Keys=@($groups.Pending)})){
  $tab=New-Object Windows.Controls.TabItem;$tab.Header="$($group.Title) ($($group.Keys.Count))";$tab.FontSize=13;$tab.Padding='12,7'
  $list=New-Object Windows.Controls.ListBox;$list.Background='#101827';$list.Foreground='#EEF2FF';$list.BorderThickness=0;$list.Padding=5
  [Windows.Controls.ScrollViewer]::SetHorizontalScrollBarVisibility($list,'Disabled')
  $n=0;foreach($key in $group.Keys){if(-not $dict.ContainsKey($key)){continue};$n++;$row=New-Object Windows.Controls.StackPanel;$row.Margin='4,8,4,8'
   $en=New-Object Windows.Controls.TextBlock;$en.Text="$n. $key";$en.FontSize=16;$en.FontWeight='SemiBold';$en.TextWrapping='Wrap';[void]$row.Children.Add($en)
   $cn=New-Object Windows.Controls.TextBlock;$cn.Text=$dict[$key].Meaning;$cn.FontSize=12;$cn.Foreground='#A5B4CF';$cn.TextWrapping='Wrap';$cn.Margin='0,5,0,0';[void]$row.Children.Add($cn)
   [void]$list.Items.Add($row)
  }
  if($n -eq 0){$empty=New-Object Windows.Controls.TextBlock;$empty.Text=if($group.Title -eq '已背过'){'今天还没有学习记录。'}else{'今天的新词已全部学完。'};$empty.Margin=16;$empty.Foreground='#A5B4CF';[void]$list.Items.Add($empty)}
  $tab.Content=$list;[void]$tabs.Items.Add($tab)
 }
 [void]$panel.Children.Add($tabs);$listWindow.Content=$panel;return $listWindow
}
function New-LibraryWindow([bool]$learned) {
 Check-Day;$Settings.IsOpen=$false
 $entries=@($words | Where-Object {$script:data.records.ContainsKey($_.Word) -eq $learned -and ($learned -or -not $basicWords.ContainsKey($_.Word)) -and (-not $learned -or -not $script:data.records[$_.Word].noReview)})
 $title=if($learned){'已背词库'}else{'未背词库'}
 $view=New-Object Windows.Window;$view.Title="$title · $($entries.Count) 词";$view.Width=560;$view.Height=520;$view.MinWidth=340;$view.MinHeight=300;$view.Owner=$window;$view.WindowStartupLocation='CenterOwner';$view.Background='#101827';$view.Foreground='#EEF2FF'
 $panel=New-Object Windows.Controls.DockPanel;$panel.Margin=16
 $note=New-Object Windows.Controls.TextBlock;$note.Text=if($learned){'包含所有日期已学习的词；不认识也算已学习，不代表已掌握。'}else{"已过滤 $($basicWords.Count) 个入门基础词；其余未背词按四级样本词频排序，不限于今日计划。"};$note.TextWrapping='Wrap';$note.Foreground='#A5B4CF';$note.Margin='0,0,0,12';[Windows.Controls.DockPanel]::SetDock($note,'Top');[void]$panel.Children.Add($note)
 $tabs=$null
 if($learned){
  $tabs=New-Object Windows.Controls.TabControl;$tabs.Height=36;$tabs.Margin='0,0,0,10';$tabs.Background='#101827';$tabs.BorderThickness=0
  foreach($label in @('已背单词库','不需要复习')){
   $tab=New-Object Windows.Controls.TabItem;$tab.Header=$label;$tab.Padding='12,5';$tab.Foreground='#101827';[void]$tabs.Items.Add($tab)
  }
  $tabs.SelectedIndex=0;[Windows.Controls.DockPanel]::SetDock($tabs,'Top');[void]$panel.Children.Add($tabs)
 }
 $toggle=New-Object Windows.Controls.Button;$toggle.Content='隐藏中文';$toggle.HorizontalAlignment='Left';$toggle.Padding='12,6';$toggle.Margin='0,0,0,12';$toggle.Background='#25334D';$toggle.Foreground='#EEF2FF';$toggle.BorderThickness=0;$toggle.Cursor='Hand';$toggle.ToolTip='切换词库中文释义的显示';[Windows.Controls.DockPanel]::SetDock($toggle,'Top');[void]$panel.Children.Add($toggle)
 $list=New-Object Windows.Controls.ListView;$list.Background='#182338';$list.Foreground='#EEF2FF';$list.BorderBrush='#35435E'
 # Keep rows visually unchanged on hover, selection and keyboard focus.
 $rowStyle=@'
<Style xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" TargetType="ListViewItem">
 <Setter Property="Foreground" Value="#EEF2FF"/>
 <Setter Property="Background" Value="Transparent"/>
 <Setter Property="BorderBrush" Value="Transparent"/>
 <Setter Property="BorderThickness" Value="1"/>
 <Setter Property="Padding" Value="5,4"/>
 <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
 <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
 <Setter Property="Template"><Setter.Value>
  <ControlTemplate TargetType="ListViewItem">
   <Border x:Name="RowBackground" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" Padding="{TemplateBinding Padding}" SnapsToDevicePixels="True">
    <GridViewRowPresenter Content="{TemplateBinding Content}" Columns="{Binding View.Columns, RelativeSource={RelativeSource AncestorType={x:Type ListView}}}" VerticalAlignment="Center"/>
   </Border>
  </ControlTemplate>
 </Setter.Value></Setter>
</Style>
'@
 $list.ItemContainerStyle=[Windows.Markup.XamlReader]::Parse($rowStyle)
 $grid=New-Object Windows.Controls.GridView
 foreach($column in @(@{Header='单词';Field='Word';Width=160},@{Header='中文释义';Field='Meaning';Width=650})){
  $col=New-Object Windows.Controls.GridViewColumn;$col.Header=$column.Header;$col.Width=$column.Width;$col.DisplayMemberBinding=New-Object Windows.Data.Binding $column.Field;[void]$grid.Columns.Add($col)
 }
 $toggle.Tag=@{Grid=$grid;Column=$grid.Columns[1]}
 $toggle.Add_Click({param($sender,$eventArgs)
  $parts=$sender.Tag
  if($parts.Grid.Columns.Contains($parts.Column)){
   $parts.Grid.Columns.Remove($parts.Column);$sender.Content='显示中文'
  }else{
   [void]$parts.Grid.Columns.Add($parts.Column);$sender.Content='隐藏中文'
  }
 })
 $list.View=$grid;$list.ItemsSource=$entries;[void]$panel.Children.Add($list)
 $edge=New-Object Windows.Controls.Border;$edge.BorderBrush='#5EEAD4';$edge.BorderThickness='0,0,0,4';$edge.Child=$panel;$view.Content=$edge
 $view.Tag=@{List=$list;Toggle=$toggle;LibraryMode=$learned;Tabs=$tabs;Note=$note;Dock=@{ready=$false;collapsed=$false;dragging=$false;lastInside=[datetime]::UtcNow;lastInput=[datetime]::MinValue}}
 if($learned){
  $list.Tag=$view;$tabs.Tag=$view
  $tabs.Add_SelectionChanged({param($sender,$eventArgs) if($eventArgs.OriginalSource -eq $sender){Refresh-LearnedLibrary $sender.Tag}})
  $list.Add_PreviewMouseUp({param($sender,$eventArgs)
   if($eventArgs.ChangedButton -ne [Windows.Input.MouseButton]::Left){return}
   if($eventArgs.ClickCount -gt 1){return}
   $row=$eventArgs.OriginalSource
   while($row -and -not ($row -is [Windows.Controls.ListViewItem])){
    if(-not ($row -is [Windows.Media.Visual])){return}
    $row=[Windows.Media.VisualTreeHelper]::GetParent($row)
   }
   if($row -and $row.Content -and $row.Content.Word){Move-LearnedLibraryWord $sender.Tag $row.Content.Word;$eventArgs.Handled=$true}
  })
  Refresh-LearnedLibrary $view
 }
 $view.Add_ContentRendered({param($sender,$eventArgs)
  if($DockHide.IsChecked){Update-LibraryDockBounds $sender;Set-LibraryCollapsed $sender $false $true}
  if(-not $Check){$sender.Tag.Timer.Start()}
 })
 $view.Add_MouseEnter({param($sender,$eventArgs)
  if($Check){return}
  $sender.Tag.Dock.lastInside=[datetime]::UtcNow
  if($DockHide.IsChecked -and $sender.Tag.Dock.collapsed){Set-LibraryCollapsed $sender $false}
 })
 $view.Add_PreviewKeyDown({param($sender,$eventArgs) $sender.Tag.Dock.lastInput=[datetime]::UtcNow})
 $view.Add_SizeChanged({param($sender,$eventArgs)
  if($sender.IsLoaded -and $DockHide.IsChecked){Update-LibraryDockBounds $sender;Set-LibraryCollapsed $sender ([bool]$sender.Tag.Dock.collapsed) $true}
 })
 $hover=New-Object Windows.Threading.DispatcherTimer ([Windows.Threading.DispatcherPriority]::Input);$hover.Interval=[timespan]::FromMilliseconds(30)
 $view.Tag.Timer=$hover;$script:libraryDrawers[$hover]=$view
 $hover.Add_Tick({param($sender,$eventArgs) Invoke-LibraryDockTick $script:libraryDrawers[$sender]})
 $view.Add_Closed({param($sender,$eventArgs) $sender.Tag.Timer.Stop();$script:libraryDrawers.Remove($sender.Tag.Timer)})
 return $view
}
function Refresh-LearnedLibrary($view) {
 $excluded=$view.Tag.Tabs.SelectedIndex -eq 1
 $learnedEntries=@($words | Where-Object {$script:data.records.ContainsKey($_.Word) -and -not $script:data.records[$_.Word].noReview})
 $excludedEntries=@($words | Where-Object {$script:data.records.ContainsKey($_.Word) -and $script:data.records[$_.Word].noReview})
 $view.Tag.Tabs.Items[0].Header="已背单词库 ($($learnedEntries.Count))"
 $view.Tag.Tabs.Items[1].Header="不需要复习 ($($excludedEntries.Count))"
 if($excluded){
  $view.Tag.List.ItemsSource=$excludedEntries;$view.Title="不需要复习 · $($excludedEntries.Count) 词"
  $view.Tag.Note.Text='这里的词不再安排复习；点击单词可移回已背单词库，恢复原复习安排。'
 }else{
  $view.Tag.List.ItemsSource=$learnedEntries;$view.Title="已背单词库 · $($learnedEntries.Count) 词"
  $view.Tag.Note.Text='点击单词可移入「不需要复习」，停止后续复习；原学习记录保留。'
 }
}
function Move-LearnedLibraryWord($view,[string]$key) {
 $oldCurrent=$script:current
 Set-NoReview $script:data $key ($view.Tag.Tabs.SelectedIndex -eq 0)
 # Refill only today's remaining slots; keep completions and old-day plans.
 $script:data.planOrderVersion.Remove($script:date)
 Initialize-Day $script:data $studyWords $script:date $script:orderVersion @(Get-PendingPriorityKeys $script:data $script:priorityBatchId)
 if($script:mode -eq 'new'){$script:queue=@($script:data.plans[$script:date] | Where-Object {-not $basicWords.ContainsKey($_) -and -not ($script:data.records.ContainsKey($_) -and $script:data.records[$_].noReview)})}
 else{$script:queue=@(Get-ReviewKeys $script:data ($script:mode -eq 'wrong') | Where-Object {-not $basicWords.ContainsKey($_)})}
 $script:pos=[array]::IndexOf($script:queue,$oldCurrent)
 if($script:pos -lt 0){
  $script:pos=0
  if($script:mode -eq 'new'){while($script:pos -lt $script:queue.Count -and $script:data.completed[$script:date] -contains $script:queue[$script:pos]){$script:pos++}}
 }
 $script:current=if($script:pos -lt $script:queue.Count){$script:queue[$script:pos]}else{$null}
 if($script:current -ne $oldCurrent){$EnglishInput.Clear();$Spelling.Clear();$script:wasWrong=$false;$script:answer=$false}
 Save-State;Render-Word;Refresh-LearnedLibrary $view
}
function Update-LibraryDockBounds($view) {
 if(-not $view.IsLoaded){return}
 $screen=[Windows.Forms.Screen]::FromHandle((New-Object Windows.Interop.WindowInteropHelper $view).Handle)
 $matrix=([Windows.PresentationSource]::FromVisual($view)).CompositionTarget.TransformFromDevice
 $corner=$matrix.Transform((New-Object Windows.Point $screen.WorkingArea.Left,$screen.WorkingArea.Top))
 $right=$matrix.Transform((New-Object Windows.Point $screen.WorkingArea.Right,$screen.WorkingArea.Bottom))
 $dock=$view.Tag.Dock;$dock.expandedTop=$corner.Y;$dock.hiddenTop=$corner.Y-$view.ActualHeight+6
 if(-not $dock.ready){
  $desired=$window.Left+$window.ActualWidth+8
  if($desired+$view.ActualWidth -gt $right.X){$desired=$window.Left-$view.ActualWidth-8}
  $view.Left=$desired
 }
 $view.Left=[Math]::Max($corner.X,[Math]::Min($view.Left,$right.X-$view.ActualWidth))
 $dock.ready=$true;$view.Topmost=$true
}
function Set-LibraryCollapsed($view,[bool]$collapsed,[bool]$instant=$false) {
 $dock=$view.Tag.Dock;if(-not $dock.ready){return}
 if(-not $instant -and $dock.collapsed -eq $collapsed){return}
 $dock.collapsed=$collapsed
 $target=if($collapsed){$dock.hiddenTop}else{$dock.expandedTop}
 if($instant){$view.BeginAnimation([Windows.Window]::TopProperty,$null);$view.Top=$target;return}
 $animation=New-Object Windows.Media.Animation.DoubleAnimation
 $animation.From=$view.Top;$animation.To=$target;$animation.Duration=[timespan]::FromMilliseconds(180)
 $ease=New-Object Windows.Media.Animation.SineEase;$ease.EasingMode='EaseOut';$animation.EasingFunction=$ease
 $animation.FillBehavior='HoldEnd';[Windows.Media.Animation.Timeline]::SetDesiredFrameRate($animation,60)
 $view.BeginAnimation([Windows.Window]::TopProperty,$animation,[Windows.Media.Animation.HandoffBehavior]::SnapshotAndReplace)
}
function Update-LibraryHover($view,[bool]$inside) {
 $dock=$view.Tag.Dock
 if($inside){$dock.lastInside=[datetime]::UtcNow;if($dock.collapsed){Set-LibraryCollapsed $view $false};return}
 if($view.IsActive -and ([datetime]::UtcNow-$dock.lastInput).TotalSeconds -lt 1.2){return}
 if(-not $dock.collapsed -and ([datetime]::UtcNow-$dock.lastInside).TotalMilliseconds -ge 220){Set-LibraryCollapsed $view $true}
}
function Invoke-LibraryDockTick($view) {
 if(-not $view -or -not $view.IsLoaded -or $view.WindowState -ne 'Normal'){return}
 $dock=$view.Tag.Dock
 if(-not $DockHide.IsChecked){if($dock.collapsed){Set-LibraryCollapsed $view $false};return}
 if(-not $dock.ready){Update-LibraryDockBounds $view;Set-LibraryCollapsed $view $false $true}
 if([Windows.Input.Mouse]::LeftButton -eq 'Pressed'){$dock.dragging=$true;$dock.lastInside=[datetime]::UtcNow;return}
 if($dock.dragging){$dock.dragging=$false;Update-LibraryDockBounds $view;Set-LibraryCollapsed $view $false $true;$dock.lastInside=[datetime]::UtcNow}
 $cursor=[Windows.Forms.Cursor]::Position
 $matrix=([Windows.PresentationSource]::FromVisual($view)).CompositionTarget.TransformFromDevice
 $point=$matrix.Transform((New-Object Windows.Point $cursor.X,$cursor.Y))
 $bottom=if($dock.collapsed){$dock.expandedTop+14}else{$dock.expandedTop+$view.ActualHeight+8}
 $inside=$view.IsMouseOver -or ($point.X -ge $view.Left-8 -and $point.X -le $view.Left+$view.ActualWidth+8 -and $point.Y -ge $dock.expandedTop-2 -and $point.Y -le $bottom)
 Update-LibraryHover $view $inside
}
function Show-LibraryWindow([bool]$learned) {
 foreach($existing in @($script:libraryDrawers.Values)){
  if($existing.Tag.LibraryMode -eq $learned){Set-LibraryCollapsed $existing $false;$existing.Tag.Dock.lastInside=[datetime]::UtcNow;[void]$existing.Activate();return}
  $existing.Close()
 }
 $libraryWindow=New-LibraryWindow $learned;$libraryWindow.Show()
}
$LearnedLibrary.Add_Click({Show-LibraryWindow $true})
$PendingLibrary.Add_Click({Show-LibraryWindow $false})
$ListButton.Add_Click({$listWindow=New-DayListWindow;[void]$listWindow.ShowDialog()})
$timer=New-Object Windows.Threading.DispatcherTimer;$timer.Interval=[timespan]::FromSeconds(15)
$timer.Add_Tick({Move-Word 1;if($null -eq $script:current){$Auto.IsChecked=$false;$timer.Stop()}})
$Auto.Add_Click({if($Auto.IsChecked){$timer.Interval=[timespan]::FromSeconds([int]$Seconds.SelectedItem.Content);$timer.Start()}else{$timer.Stop()}})
$Seconds.Add_SelectionChanged({if($Seconds.SelectedItem){$script:data.settings.seconds=[int]$Seconds.SelectedItem.Content;$timer.Interval=[timespan]::FromSeconds($script:data.settings.seconds)}})
$window.Add_PreviewKeyDown({param($sender,$e)
 if($e.OriginalSource -is [Windows.Controls.TextBox]){if($e.Key -eq 'Return'){if($e.OriginalSource -eq $EnglishInput){[void]$Spelling.Focus()}else{Submit-Spelling};$e.Handled=$true};return}
 if($e.OriginalSource -is [Windows.Controls.Primitives.RangeBase] -or $e.OriginalSource -is [Windows.Controls.ComboBox]){return}
 if($e.Key -eq 'Space'){$ChineseButton.RaiseEvent((New-Object Windows.RoutedEventArgs ([Windows.Controls.Button]::ClickEvent)));$e.Handled=$true}
 elseif($e.Key -eq 'Right'){Move-Word 1;$e.Handled=$true}elseif($e.Key -eq 'Left'){Move-Word -1;$e.Handled=$true}
 elseif($e.Key -eq 'R' -and [Windows.Input.Keyboard]::Modifiers -eq 'Control'){Speak-Word;$e.Handled=$true}
})
$window.Add_Closing({if($script:dockTimer){$script:dockTimer.Stop()};$timer.Stop();Save-State;if($speech){$speech.Dispose()};if($script:instance){$script:instance.ReleaseMutex();$script:instance.Dispose()}})
$s=$script:data.settings;if($s.layoutVersion -ne 9 -and $s.layoutVersion -ne 10){$s.font=20};$FontSlider.Value=$s.font;$Word.FontSize=$s.font;$OpacitySlider.Value=$s.opacity;$window.Opacity=$s.opacity;$Pin.IsChecked=$s.pin;$window.Topmost=$s.pin
if($s.layoutVersion -ne 10){$s.width=[Math]::Max(240,$s.width);$s.height=[Math]::Max(400,$s.height);$s.layoutVersion=10}
$window.Width=[Math]::Max(220,$s.width);$window.Height=[Math]::Max(300,$s.height)
if($s.left -ge 0 -and $s.top -ge 0 -and $s.left -lt [Windows.SystemParameters]::VirtualScreenWidth-100 -and $s.top -lt [Windows.SystemParameters]::VirtualScreenHeight-100){$window.WindowStartupLocation='Manual';$window.Left=$s.left;$window.Top=$s.top}
for($i=0;$i -lt $Seconds.Items.Count;$i++){if([int]$Seconds.Items[$i].Content -eq $s.seconds){$Seconds.SelectedIndex=$i}}
# Top-edge hover drawer.
Add-Type -AssemblyName System.Windows.Forms
$script:dock=@{collapsed=$false;ready=$false;dragging=$false;expandedTop=0.0;hiddenTop=0.0;lastInside=[datetime]::UtcNow;lastInput=[datetime]::MinValue}
if($script:data.settings.ContainsKey('dockHide')){$DockHide.IsChecked=[bool]$script:data.settings.dockHide}
function Update-DockBounds {
 if(-not $window.IsLoaded){return}
 $hwnd=(New-Object Windows.Interop.WindowInteropHelper $window).Handle
 $screen=[Windows.Forms.Screen]::FromHandle($hwnd)
 $matrix=([Windows.PresentationSource]::FromVisual($window)).CompositionTarget.TransformFromDevice
 $corner=$matrix.Transform((New-Object Windows.Point $screen.WorkingArea.Left,$screen.WorkingArea.Top))
 $right=$matrix.Transform((New-Object Windows.Point $screen.WorkingArea.Right,$screen.WorkingArea.Bottom))
 $script:dock.expandedTop=$corner.Y;$script:dock.hiddenTop=$corner.Y-$window.ActualHeight+6
 $window.Left=[Math]::Max($corner.X,[Math]::Min($window.Left,$right.X-$window.ActualWidth));$script:dock.ready=$true
}
function Set-DockCollapsed([bool]$collapsed,[bool]$instant=$false) {
 if(-not $script:dock.ready){return}
 if(-not $instant -and $script:dock.collapsed -eq $collapsed){return}
 $script:dock.collapsed=$collapsed
 $target=if($collapsed){$script:dock.hiddenTop}else{$script:dock.expandedTop}
 $start=$window.Top
 if($instant){$window.BeginAnimation([Windows.Window]::TopProperty,$null);$window.Top=$target;return}
 # Replace the running animation from its CURRENT visual position. Do not move
 # the native window to the destination first: that caused jumps and flicker.
 $a=New-Object Windows.Media.Animation.DoubleAnimation
 $a.From=$start;$a.To=$target
 $distance=[Math]::Abs($target-$start)/[Math]::Max(1,$window.ActualHeight-6)
 $a.Duration=[timespan]::FromMilliseconds([Math]::Max(90,180*$distance))
 $ease=New-Object Windows.Media.Animation.SineEase;$ease.EasingMode='EaseOut';$a.EasingFunction=$ease
 $a.FillBehavior='HoldEnd'
 [Windows.Media.Animation.Timeline]::SetDesiredFrameRate($a,60)
 $window.BeginAnimation([Windows.Window]::TopProperty,$a,[Windows.Media.Animation.HandoffBehavior]::SnapshotAndReplace)
}
function Test-DockPointer {
 $cursor=[Windows.Forms.Cursor]::Position
 $matrix=([Windows.PresentationSource]::FromVisual($window)).CompositionTarget.TransformFromDevice
 $p=$matrix.Transform((New-Object Windows.Point $cursor.X,$cursor.Y))
 $left=$window.Left-8;$right=$window.Left+$window.ActualWidth+8
 $top=$script:dock.expandedTop
 $bottom=if($script:dock.collapsed){$top+14}else{$top+$window.ActualHeight+8}
 ($p.X -ge $left -and $p.X -le $right -and $p.Y -ge $top-2 -and $p.Y -le $bottom)
}
$window.Add_MouseEnter({if(-not $Check -and $DockHide.IsChecked){$script:dock.lastInside=[datetime]::UtcNow;if($script:dock.collapsed){Set-DockCollapsed $false}}})
$window.Add_PreviewKeyDown({$script:dock.lastInput=[datetime]::UtcNow})
$DragHandle.Add_MouseLeftButtonDown({
 if($SettingsButton.IsMouseOver){return};$script:dock.dragging=$true
 try{if($DockHide.IsChecked){Set-DockCollapsed $false $true};$window.DragMove()}
 finally{$script:dock.dragging=$false;if($DockHide.IsChecked){Update-DockBounds;Set-DockCollapsed $false};$script:dock.lastInside=[datetime]::UtcNow;Save-State}
})
$DockHide.Add_Click({if($DockHide.IsChecked){Update-DockBounds;$Pin.IsChecked=$true;$window.Topmost=$true;Set-DockCollapsed $false;$script:dock.lastInside=[datetime]::UtcNow}else{Set-DockCollapsed $false};Save-State})
$CloseWidget.Add_Click({$Settings.IsOpen=$false;$window.Close()})
$script:dockTimer=New-Object Windows.Threading.DispatcherTimer ([Windows.Threading.DispatcherPriority]::Input);$script:dockTimer.Interval=[timespan]::FromMilliseconds(30)
$script:dockTimer.Add_Tick({
 if(-not $DockHide.IsChecked -or -not $script:dock.ready -or $window.WindowState -ne 'Normal'){return}
 $blockingChild=@($window.OwnedWindows | Where-Object {-not ($_.Tag -is [hashtable] -and $_.Tag.ContainsKey('LibraryMode'))}).Count -gt 0
 if($script:dock.dragging -or $Settings.IsOpen -or $blockingChild){$script:dock.lastInside=[datetime]::UtcNow;return}
 if($window.IsMouseOver -or (Test-DockPointer)){$script:dock.lastInside=[datetime]::UtcNow;if($script:dock.collapsed){Set-DockCollapsed $false};return}
 if($window.IsActive -and $window.IsKeyboardFocusWithin -and ([datetime]::UtcNow-$script:dock.lastInput).TotalSeconds -lt 1.2){return}
 if(-not $script:dock.collapsed -and ([datetime]::UtcNow-$script:dock.lastInside).TotalMilliseconds -ge 220){Set-DockCollapsed $true}
})
$window.Add_ContentRendered({if($DockHide.IsChecked){Update-DockBounds;$Pin.IsChecked=$true;$window.Topmost=$true;Set-DockCollapsed $false $true};if(-not $Check){$script:dockTimer.Start()}})
Start-Session 'new'
$window.Add_ContentRendered({[void]$EnglishInput.Focus()})
if($Check){
 foreach($entry in $words){
  if(-not $phonetics.ContainsKey($entry.Word.ToLowerInvariant())){throw "Missing IPA: $($entry.Word)"}
 }
 if($script:current -and $phonetics[$script:current].ipa -and $Phonetic.Text -notmatch '^[美英] /'){throw 'Current IPA did not render'}
 $previousChinese=$script:data.settings.chinese;$script:data.settings.chinese=$false;Render-Word
 if($Phonetic.Visibility -ne 'Visible'){throw 'Hiding Chinese hid IPA'}
 $script:data.settings.chinese=$previousChinese;Render-Word
 foreach($entry in $words){
  if(-not @(Get-MeaningAnswers $entry.Word).Count){throw "No usable Chinese answer: $($entry.Word)"}
 }
 if($dict.ContainsKey('reservior') -or -not $dict.ContainsKey('reservoir')){throw 'Reservoir spelling correction failed'}
 if($dict['tighten'].Meaning -notmatch '^v\.' -or $dict['gratitude'].Meaning -notmatch '^n\.') {throw 'Corrected parts of speech were not loaded'}
 if(@(Get-MeaningAnswers 'voyage') -contains '字'){throw 'Bad voyage meaning remains'}
 $aliasTest=New-LearningState
 $aliasTest.records['reservior']=@{streak=2;lapses=1}
 $aliasTest.plans['test']=@('reservior','reservoir','acquire')
 $aliasTest.completed['test']=@('reservior')
 $aliasTest.activity=@{test=@('reservior')}
 Repair-VocabularyKeys $aliasTest
 Repair-VocabularyKeys $aliasTest
 if($aliasTest.records.ContainsKey('reservior') -or $aliasTest.records['reservoir'].streak -ne 2 -or $aliasTest.plans['test'].Count -ne 2 -or $aliasTest.completed['test'][0] -ne 'reservoir' -or $aliasTest.activity['test'][0] -ne 'reservoir'){throw 'Vocabulary progress migration failed'}
 $savedData=Convert-Map ($script:data | ConvertTo-Json -Depth 12 | ConvertFrom-Json)
 $originalKey=$script:current;$originalPos=$script:pos;$originalDone=@($script:data.completed[$script:date]).Count
 $Spelling.Text='';Submit-Spelling
 if($script:pos -ne $originalPos -or @($script:data.completed[$script:date]).Count -ne $originalDone){throw 'Empty spelling advanced or counted'}
 $Spelling.Text=$originalKey;Move-Word 1
 if($script:pos -ne $originalPos){throw 'English input advanced'}
 $Spelling.Text='错误释义测试';Submit-Spelling
 if($script:pos -ne $originalPos){throw 'Incorrect Chinese meaning advanced'}
 $validAnswers=@(Get-MeaningAnswers $originalKey)
 $Spelling.Text=$validAnswers[0];$EnglishInput.Text=$originalKey+'x';Submit-Spelling
 if($script:pos -ne $originalPos){throw 'Incorrect English advanced with correct Chinese'}
 $EnglishInput.Text=$originalKey.ToUpperInvariant();$Spelling.Text='错误释义测试';Submit-Spelling
 if($script:pos -ne $originalPos){throw 'Correct English advanced with incorrect Chinese'}
 foreach($valid in $validAnswers){$Spelling.Text=$valid;if(-not (Test-Spelling)){throw 'A valid meaning rejected'}}
 $lapsesBeforeSubmit=[int]$script:data.records[$originalKey].lapses
 $Spelling.Text=' '+$validAnswers[0]+'。 ';Submit-Spelling
 if($script:pos -ne $originalPos+1 -or $Spelling.Text -ne '' -or $EnglishInput.Text -ne ''){throw 'Correct bilingual answer did not advance and clear'}
 if($script:data.records[$originalKey].lapses -ne ($lapsesBeforeSubmit+1)){throw 'Bilingual submission was not recorded as wrong'}
 $doneBeforeBack=@($script:data.completed[$script:date]).Count;Move-Word -1
 if($script:current -ne $originalKey -or @($script:data.completed[$script:date]).Count -ne $doneBeforeBack){throw 'Previous word changed progress or failed'}
 $Spelling.Text=@(Get-MeaningAnswers $originalKey)[0];$EnglishInput.Text=$originalKey;Move-Word 1
 Rate-Word $false;$wrongKey=$script:current;$Spelling.Text=@(Get-MeaningAnswers $wrongKey)[0];$EnglishInput.Text=$wrongKey;Submit-Spelling
 if($script:data.records[$wrongKey].streak -ne 0){throw 'Wrong word became known after copying'}
 $script:data=Convert-Map ($savedData | ConvertTo-Json -Depth 12 | ConvertFrom-Json);Start-Session 'new'
 $testKey=$script:current;$testPos=$script:pos
 $Good.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
 if($script:pos -ne $testPos+1 -or $script:data.completed[$script:date] -notcontains $testKey){throw 'Known button did not advance and record with empty inputs'}
 $script:data=$savedData;Start-Session 'new'
 $window.Show();$window.UpdateLayout()
 Update-DockBounds
 if(-not $script:dock.ready){throw 'Dock screen bounds missing'}
 Set-DockCollapsed $true $true
 if(-not $script:dock.collapsed -or [Math]::Abs(($window.Top+$window.ActualHeight)-$script:dock.expandedTop-6) -gt 1){throw 'Hidden drawer does not leave the six-pixel handle'}
 Set-DockCollapsed $false $true
 if($script:dock.collapsed -or [Math]::Abs($window.Top-$script:dock.expandedTop) -gt 1){throw 'Drawer did not expand to screen edge'}
 function Wait-DockFrame([int]$ms) {
  $frame=New-Object Windows.Threading.DispatcherFrame
  $clock=New-Object Windows.Threading.DispatcherTimer
  $clock.Interval=[timespan]::FromMilliseconds($ms)
  $clock.Add_Tick({$frame.Continue=$false}.GetNewClosure())
  $clock.Start();[Windows.Threading.Dispatcher]::PushFrame($frame);$clock.Stop()
 }
 Wait-DockFrame 40
 Set-DockCollapsed $false $true
 Set-DockCollapsed $true
 Wait-DockFrame 60
 $midpoint=$window.Top
 if($midpoint -le $script:dock.hiddenTop+1 -or $midpoint -ge $script:dock.expandedTop-1){throw "Slide intermediate check failed: top=$midpoint hidden=$($script:dock.hiddenTop) expanded=$($script:dock.expandedTop) collapsed=$($script:dock.collapsed)"}
 Set-DockCollapsed $false
 if([Math]::Abs($window.Top-$midpoint) -gt 3){throw 'Reversing slide caused a position jump'}
 Wait-DockFrame 260
 if([Math]::Abs($window.Top-$script:dock.expandedTop) -gt 2){throw 'Slide did not finish at screen edge'}
 $bitmap=New-Object Windows.Media.Imaging.RenderTargetBitmap ([int]$window.ActualWidth),([int]$window.ActualHeight),96,96,([Windows.Media.PixelFormats]::Pbgra32)
 $bitmap.Render($window);$encoder=New-Object Windows.Media.Imaging.PngBitmapEncoder;$encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
 $stream=[IO.File]::Create((Join-Path $checkOutputRoot 'preview.png'));try{$encoder.Save($stream)}finally{$stream.Dispose()}
 $dayLists=Get-DayWordLists $script:data $script:date
 if(@($dayLists.Learned | Where-Object {$dayLists.Pending -contains $_}).Count){throw 'Learned and pending overlap'}
 $listWindow=New-DayListWindow;$listWindow.Show();$listWindow.UpdateLayout()
 $bitmap=New-Object Windows.Media.Imaging.RenderTargetBitmap ([int]$listWindow.ActualWidth),([int]$listWindow.ActualHeight),96,96,([Windows.Media.PixelFormats]::Pbgra32);$bitmap.Render($listWindow)
 $encoder=New-Object Windows.Media.Imaging.PngBitmapEncoder;$encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap));$stream=[IO.File]::Create((Join-Path $checkOutputRoot 'today-preview.png'));try{$encoder.Save($stream)}finally{$stream.Dispose()};$listWindow.Close()
 $learnedView=New-LibraryWindow $true;$pendingView=New-LibraryWindow $false
 $excludedPending=@($words | Where-Object {$basicWords.ContainsKey($_.Word) -and -not $script:data.records.ContainsKey($_.Word)}).Count
 $noReviewCount=@($words | Where-Object {$script:data.records.ContainsKey($_.Word) -and $script:data.records[$_.Word].noReview}).Count
 if(($learnedView.Tag.List.Items.Count+$pendingView.Tag.List.Items.Count+$excludedPending+$noReviewCount) -ne $words.Count){throw 'Library partition mismatch'}
 if(@($pendingView.Tag.List.Items | Where-Object {$basicWords.ContainsKey($_.Word)}).Count){throw 'Beginner word remains in pending library'}
 foreach($libraryView in @($learnedView,$pendingView)){
  $libraryToggle=$libraryView.Tag.Toggle;$libraryGrid=$libraryView.Tag.List.View
  $countBefore=$libraryView.Tag.List.Items.Count
  $libraryView.Show();$libraryView.UpdateLayout();Wait-DockFrame 80
  if(-not $libraryView.Tag.Dock.ready -or [Math]::Abs($libraryView.Top-$libraryView.Tag.Dock.expandedTop) -gt 1){throw 'Library did not dock at screen edge'}
  if(-not $window.IsEnabled){throw 'Library blocked main window'}
  if($libraryView -eq $learnedView -and $countBefore -gt 0){
   $libraryStateBackup=Convert-Map ($script:data | ConvertTo-Json -Depth 14 | ConvertFrom-Json)
   $movedKey=$libraryView.Tag.List.Items[0].Word;$oldDue=$script:data.records[$movedKey].due;$oldStreak=$script:data.records[$movedKey].streak
   $clickedRow=$libraryView.Tag.List.ItemContainerGenerator.ContainerFromIndex(0)
   $libraryClick=New-Object Windows.Input.MouseButtonEventArgs ([Windows.Input.Mouse]::PrimaryDevice),([Environment]::TickCount),([Windows.Input.MouseButton]::Left)
   $libraryClick.RoutedEvent=[Windows.Input.Mouse]::PreviewMouseUpEvent;$clickedRow.RaiseEvent($libraryClick)
   if(-not $script:data.records[$movedKey].noReview -or @($libraryView.Tag.List.Items | Where-Object {$_.Word -eq $movedKey}).Count){throw 'Learned word was not moved out'}
   if(@(Get-ReviewKeys $script:data) -contains $movedKey -or @(Get-ReviewKeys $script:data $true) -contains $movedKey -or @(Get-PendingPriorityKeys $script:data $script:priorityBatchId) -contains $movedKey){throw 'No-review word is still scheduled'}
   $libraryView.Tag.Tabs.SelectedIndex=1;$libraryView.UpdateLayout()
   if(-not @($libraryView.Tag.List.Items | Where-Object {$_.Word -eq $movedKey}).Count){throw 'No-review library is missing moved word'}
   $noReviewBitmap=New-Object Windows.Media.Imaging.RenderTargetBitmap ([int]$libraryView.ActualWidth),([int]$libraryView.ActualHeight),96,96,([Windows.Media.PixelFormats]::Pbgra32);$noReviewBitmap.Render($libraryView)
   $noReviewEncoder=New-Object Windows.Media.Imaging.PngBitmapEncoder;$noReviewEncoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($noReviewBitmap));$noReviewStream=[IO.File]::Create((Join-Path $checkOutputRoot 'no-review-preview.png'));try{$noReviewEncoder.Save($noReviewStream)}finally{$noReviewStream.Dispose()}
   Move-LearnedLibraryWord $libraryView $movedKey
   if($script:data.records[$movedKey].noReview -or $script:data.records[$movedKey].due -ne $oldDue -or $script:data.records[$movedKey].streak -ne $oldStreak){throw 'Restore changed original learning record'}
   $script:data=$libraryStateBackup;Start-Session 'new';$libraryView.Tag.Tabs.SelectedIndex=0;Refresh-LearnedLibrary $libraryView
  }
  $libraryToggle.RaiseEvent((New-Object Windows.RoutedEventArgs ([Windows.Controls.Button]::ClickEvent)))
  if($libraryGrid.Columns.Count -ne 1 -or $libraryToggle.Content -ne '显示中文'){throw 'Library Chinese did not hide'}
  $libraryView.Tag.Dock.lastInside=[datetime]::UtcNow.AddSeconds(-2)
  Update-LibraryHover $libraryView $false
  Wait-DockFrame 260
  if(-not $libraryView.Tag.Dock.collapsed -or [Math]::Abs(($libraryView.Top+$libraryView.ActualHeight)-$libraryView.Tag.Dock.expandedTop-6) -gt 1){throw 'Library did not leave six-pixel handle'}
  Update-LibraryHover $libraryView $true
  Wait-DockFrame 260
  if($libraryView.Tag.Dock.collapsed -or [Math]::Abs($libraryView.Top-$libraryView.Tag.Dock.expandedTop) -gt 1 -or $libraryGrid.Columns.Count -ne 1){throw 'Library hover restore lost state'}
  $libraryToggle.RaiseEvent((New-Object Windows.RoutedEventArgs ([Windows.Controls.Button]::ClickEvent)))
  if($libraryGrid.Columns.Count -ne 2 -or $libraryToggle.Content -ne '隐藏中文' -or $libraryView.Tag.List.Items.Count -ne $countBefore){throw 'Library Chinese did not restore'}
  if($libraryView -eq $pendingView){
   $libraryView.Tag.List.SelectedIndex=0;$libraryView.Tag.List.ScrollIntoView($libraryView.Tag.List.Items[0]);$libraryView.UpdateLayout()
   $selectedRow=$libraryView.Tag.List.ItemContainerGenerator.ContainerFromIndex(0);[void]$selectedRow.ApplyTemplate()
   $selectedBackground=$selectedRow.Template.FindName('RowBackground',$selectedRow)
   if($selectedBackground.Background.ToString() -ne '#00FFFFFF' -or $selectedRow.Foreground.ToString() -ne '#FFEEF2FF' -or $selectedRow.Template.Triggers.Count -ne 0){throw 'Library row appearance changed on interaction'}
   $libraryView.UpdateLayout();$libraryBitmap=New-Object Windows.Media.Imaging.RenderTargetBitmap ([int]$libraryView.ActualWidth),([int]$libraryView.ActualHeight),96,96,([Windows.Media.PixelFormats]::Pbgra32);$libraryBitmap.Render($libraryView)
   $libraryEncoder=New-Object Windows.Media.Imaging.PngBitmapEncoder;$libraryEncoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($libraryBitmap));$libraryStream=[IO.File]::Create((Join-Path $checkOutputRoot 'library-preview.png'));try{$libraryEncoder.Save($libraryStream)}finally{$libraryStream.Dispose()}
  }
  $libraryView.Hide()
 }
 $learnedView.Close();$pendingView.Close()
 if($script:libraryDrawers.Count -ne 0){throw 'Closed library retained hover timer'}
 Write-Output "CHECK OK: $($words.Count) words; today plan $($script:data.plans[$script:date].Count); original progress preserved.";$window.Close();exit
}
[void]$window.ShowDialog()
