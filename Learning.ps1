function Get-StudyDate { [TimeZoneInfo]::ConvertTimeBySystemTimeZoneId([datetime]::UtcNow,'China Standard Time').ToString('yyyy-MM-dd') }
function New-LearningState { @{records=@{};plans=@{};completed=@{};settings=@{chinese=$true;pin=$true;font=34;opacity=1.0;seconds=15;width=420;height=600;left=-1;top=-1}} }
function Repair-VocabularyKeys($s) {
 # A source typo duplicated reservoir. Keep old learning data recoverable.
 if($s.records.ContainsKey('reservior')){
  if(-not $s.ContainsKey('vocabularyAliasBackup')){$s.vocabularyAliasBackup=@{}}
  $s.vocabularyAliasBackup['reservior']=$s.records['reservior']
  if(-not $s.records.ContainsKey('reservoir')){$s.records['reservoir']=$s.records['reservior']}
  $s.records.Remove('reservior')
 }
 foreach($section in @('plans','completed','activity')){
  if(-not $s.ContainsKey($section)){continue}
  foreach($day in @($s[$section].Keys)){
   $s[$section][$day]=@($s[$section][$day] | ForEach-Object {if($_ -eq 'reservior'){'reservoir'}else{$_}} | Select-Object -Unique)
  }
 }
}
function Initialize-PriorityBatch($s,[string]$batchId,$keys) {
 if(-not $s.ContainsKey('priorityBatches')){$s.priorityBatches=@{}}
 if(-not $s.priorityBatches.ContainsKey($batchId)){$s.priorityBatches[$batchId]=@{keys=@($keys);completed=@()}}
}
function Get-PendingPriorityKeys($s,[string]$batchId) {
 if(-not $batchId -or -not $s.ContainsKey('priorityBatches') -or -not $s.priorityBatches.ContainsKey($batchId)){return @()}
 $batch=$s.priorityBatches[$batchId]
 @($batch.keys | Where-Object {$batch.completed -notcontains $_ -and -not ($s.records.ContainsKey($_) -and $s.records[$_].noReview)})
}
function Set-NoReview($s,[string]$key,[bool]$disabled) {
 if(-not $s.records.ContainsKey($key)){throw 'Only learned words can be moved between review libraries.'}
 $s.records[$key].noReview=$disabled
}
function Initialize-Day($s,$words,$day,[string]$orderVersion='',$priorityKeys=@()) {
 if(-not $s.ContainsKey('activity')){$s.activity=@{}}
 if(-not $s.activity.ContainsKey($day)){$s.activity[$day]=@()}
 if(-not $s.completed.ContainsKey($day)){$s.completed[$day]=@()}
 if(-not $s.ContainsKey('planOrderVersion')){$s.planOrderVersion=@{}}
 $newOrder=$orderVersion -and $s.planOrderVersion[$day] -ne $orderVersion
 if(-not $s.plans.ContainsKey($day) -or $newOrder){
  if($s.plans.ContainsKey($day) -and $newOrder){
   if(-not $s.ContainsKey('planOrderBackup')){$s.planOrderBackup=@{}}
   if(-not $s.planOrderBackup.ContainsKey($day)){$s.planOrderBackup[$day]=@($s.plans[$day])}
  }
  $done=@($s.completed[$day] | Select-Object -Unique)
  $remaining=[Math]::Max(0,100-$done.Count)
  $priority=@($priorityKeys | Where-Object {$done -notcontains $_ -and -not ($s.records.ContainsKey($_) -and $s.records[$_].noReview)} | Select-Object -Unique)
  $regular=@($words | Where-Object {-not $s.records.ContainsKey($_.Word) -and $done -notcontains $_.Word -and $priority -notcontains $_.Word} | ForEach-Object {$_.Word})
  $pending=@((@($priority)+@($regular)) | Select-Object -First $remaining)
  $s.plans[$day]=@($done)+@($pending)
  if($orderVersion){$s.planOrderVersion[$day]=$orderVersion}
 }
}
function Set-WordRating($s,[string]$key,[bool]$correct,[string]$day,[string]$mode) {
 if(-not $s.ContainsKey('activity')){$s.activity=@{}}
 if(-not $s.activity.ContainsKey($day)){$s.activity[$day]=@()}
 if($s.activity[$day] -notcontains $key){$s.activity[$day]+=$key}
 if($s.ContainsKey('priorityBatches')){
  foreach($batch in $s.priorityBatches.Values){if($batch.keys -contains $key -and $batch.completed -notcontains $key){$batch.completed+=@($key)}}
 }
 if(-not $s.records.ContainsKey($key)){$s.records[$key]=@{first=$day;streak=0;lapses=0;due=''}}
 $r=$s.records[$key]
 if($correct){if($r.lastCorrect -ne $day){$r.streak=[int]$r.streak+1};$r.lastCorrect=$day;$days=@(1,3,7,14,30);$r.due=[datetime]::UtcNow.AddDays($days[[Math]::Min($r.streak-1,4)]).ToString('o')}
 else{$r.streak=0;$r.lastCorrect='';$r.lapses=[int]$r.lapses+1;$r.due=[datetime]::UtcNow.AddMinutes(10).ToString('o')}
 if($mode -eq 'new' -and $s.completed[$day] -notcontains $key){$s.completed[$day]+=$key}
}
function Get-DayWordLists($s,[string]$day) {
 $learned=@(@($s.completed[$day])+@($s.activity[$day]) | Where-Object {$_} | Select-Object -Unique)
 $pending=@($s.plans[$day] | Where-Object {$s.completed[$day] -notcontains $_ -and -not ($s.records.ContainsKey($_) -and $s.records[$_].noReview)})
 @{Learned=$learned;Pending=$pending}
}
function Get-ReviewKeys($s,[bool]$wrong=$false) {
 @($s.records.Keys | Where-Object {$r=$s.records[$_];-not $r.noReview -and (($wrong -and [int]$r.streak -eq 0) -or (-not $wrong -and $r.due -and [datetime]::Parse($r.due).ToUniversalTime() -le [datetime]::UtcNow))} | Sort-Object {$s.records[$_].due})
}
