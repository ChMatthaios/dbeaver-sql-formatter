<#
DB2 SQL Formatter - clean grid rewrite
Rule: same formatting grid for every SELECT. Nested SELECTs only add left indentation.
Comments are protected as simple text and restored.
#>

$ErrorActionPreference = "Stop"

$script:MaxLineLength = 120
$script:KeywordCasing = "Uppercase"
$script:ProtectedMap = @{}
$script:ProtectedIndex = 0

function Load-SqlfmtSettings {
    $p = Join-Path $PSScriptRoot "settings\settings.json"
    if (-not (Test-Path $p)) { return }
    try {
        $s = Get-Content $p -Raw | ConvertFrom-Json
        if ($s.PSObject.Properties.Name -contains "maxLineLength") {
            $v = [int]$s.maxLineLength
            if ($v -ge 40 -and $v -le 300) { $script:MaxLineLength = $v }
        }
        if ($s.PSObject.Properties.Name -contains "keywordCasing") {
            $v = [string]$s.keywordCasing
            if ($v -in @("Uppercase","Lowercase","Preserve")) { $script:KeywordCasing = $v }
        }
    } catch {}
}
Load-SqlfmtSettings

function New-ProtectedToken {
    param([string]$Prefix, [string]$Value)
    $script:ProtectedIndex++
    $t = "__SQLFMT_${Prefix}_$script:ProtectedIndex`__"
    $script:ProtectedMap[$t] = $Value
    return $t
}

function Protect-SqlText {
    param([string]$Sql)
    $script:ProtectedMap = @{}
    $script:ProtectedIndex = 0
    $Sql = [regex]::Replace($Sql, '/\*[\s\S]*?\*/', { param($m) New-ProtectedToken "BCOM" $m.Value })
    $Sql = [regex]::Replace($Sql, "'(?:''|[^'])*'", { param($m) New-ProtectedToken "STR" $m.Value })
    $Sql = [regex]::Replace($Sql, '"(?:""|[^"])*"', { param($m) New-ProtectedToken "DQS" $m.Value })
    $Sql = [regex]::Replace($Sql, '--[^\r\n]*', { param($m) New-ProtectedToken "LCOM" $m.Value })
    $Sql = [regex]::Replace($Sql, '(__SQLFMT_(?:LCOM|BCOM)_\d+__)(\r?\n)([ \t]*)', {
        param($m)
        return $m.Groups[1].Value + " __SQLFMT_EOL_" + $m.Groups[3].Value.Length + "__ "
    })
    return $Sql
}

function Restore-SqlText {
    param([string]$Sql)
    $Sql = [regex]::Replace($Sql, '[ \t]*__SQLFMT_EOL_\d+__[ \t]*(\r?\n)', '$1')
    $Sql = [regex]::Replace($Sql, '[ \t]*__SQLFMT_EOL_(\d+)__[ \t]*', {
        param($m)
        return [Environment]::NewLine + (' ' * [int]$m.Groups[1].Value)
    })
    foreach ($k in ($script:ProtectedMap.Keys | Sort-Object Length -Descending)) {
        $Sql = $Sql.Replace($k, $script:ProtectedMap[$k])
    }
    return $Sql
}

function Normalize-Space {
    param([string]$Text)
    if ($null -eq $Text) { return "" }
    $Text = $Text -replace '[\r\n\t]+',' '
    $Text = $Text -replace '\s+',' '
    $Text = $Text -replace '\s+,', ','
    $Text = $Text -replace ',\s*', ', '
    $Text = $Text -replace '\s+\)', ')'
    $Text = $Text -replace '\(\s+', '('
    $Text = $Text -replace '\s+;', ';'
    $Text = $Text.Trim()
    foreach ($fn in @('COUNT','SUM','AVG','MIN','MAX','COALESCE','NULLIF','TRIM','UPPER','LOWER','CAST','VARCHAR','VARCHAR_FORMAT','DECIMAL','SUBSTR','SUBSTRING','DATE','TIMESTAMP','LOCATE','ROW_NUMBER','RANK','DENSE_RANK','LAST_DAY')) {
        $Text = [regex]::Replace($Text, "(?i)\b$fn\s*\(", { param($m) ($m.Value -replace '\s*\($',' (') })
    }

    # Repair a few common glued clause boundaries from editor selection/replacement.
    # These are intentionally conservative and only target SQL keywords after obvious
    # identifier/parenthesis endings.
    $Text = [regex]::Replace($Text, '(?i)([A-Z0-9_\)])(ORDER\s+BY\b)', '$1 $2')
    $Text = [regex]::Replace($Text, '(?i)([A-Z0-9_\)])(GROUP\s+BY\b)', '$1 $2')
    $Text = [regex]::Replace($Text, '(?i)([A-Z0-9_\)])(FETCH\s+FIRST\b)', '$1 $2')
    $Text = [regex]::Replace($Text, '(?i)([A-Z0-9_\)])(WITH\s+(UR|RS|CS|RR|NC)\b)', '$1 $2')
    $Text = [regex]::Replace($Text, '(?i)([A-Z0-9_\)])(SELECT\b)', '$1 $2')
    $Text = [regex]::Replace($Text, '(?i)([A-Z0-9_\)])(FROM\b)', '$1 $2')
    $Text = [regex]::Replace($Text, '(?i)([A-Z0-9_\)])(WHERE\b)', '$1 $2')
    $Text = [regex]::Replace($Text, '(?i)([A-Z0-9_\)])(SET\b)', '$1 $2')
    $Text = [regex]::Replace($Text, '(?i)([A-Z0-9_\)])(USING\b)', '$1 $2')
    $Text = [regex]::Replace($Text, '(?i)([A-Z0-9_\)])(WHEN\b)', '$1 $2')

    return $Text
}

function Convert-SqlKeywords {
    param([string]$Sql)
    if ($script:KeywordCasing -eq "Preserve") { return $Sql }
    $kw = @('select','from','where','and','or','not','null','is','in','exists','between','like','inner','left','right','full','cross','outer','join','on','group','by','having','order','asc','desc','fetch','first','rows','only','limit','offset','with','ur','rs','cs','rr','nc','union','all','except','intersect','case','when','then','else','end','as','over','partition','insert','into','values','update','set','delete','merge','using','matched','then','create','replace','procedure','function','returns','language','sql','begin','atomic','declare','cursor','for','continue','handler','open','close','loop','leave','if','signal','sqlstate','message_text','prepare','execute','table','view','index','schema','constraint','primary','key','foreign','references','check','default','temporary','global','session','commit','preserve','logged','alter','add','column','data','type','optimize','deterministic','external','action','no','of')
    foreach ($w in $kw) {
        $e = [regex]::Escape($w)
        $Sql = [regex]::Replace($Sql, "(?i)(?<![A-Z0-9_])$e(?![A-Z0-9_])", {
            param($m)
            if ($script:KeywordCasing -eq "Lowercase") { $m.Value.ToLowerInvariant() } else { $m.Value.ToUpperInvariant() }
        })
    }
    return $Sql
}

function Strip-TrailingSemicolon { param([string]$Text) return ($Text.Trim() -replace ';+\s*$','') }

function Find-MatchingParen {
    param([string]$Text,[int]$OpenIndex)
    $d = 0
    for ($i=$OpenIndex; $i -lt $Text.Length; $i++) {
        if ($Text[$i] -eq '(') { $d++ }
        elseif ($Text[$i] -eq ')') { $d--; if ($d -eq 0) { return $i } }
    }
    return -1
}

function Get-ParenDepthAt {
    param([string]$Text,[int]$Index)
    $d=0
    for($i=0;$i -lt $Index;$i++){
        if($Text[$i] -eq '('){$d++}
        elseif($Text[$i] -eq ')' -and $d -gt 0){$d--}
    }
    return $d
}

function Get-TopLevelMatches {
    param([string]$Text,[string]$Pattern)
    $r=New-Object System.Collections.Generic.List[object]
    $rx=[regex]::new($Pattern,[System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    foreach($m in $rx.Matches($Text)){
        if((Get-ParenDepthAt $Text $m.Index) -eq 0){$r.Add($m)}
    }
    return $r
}
function Get-FirstTopLevelMatch {
    param([string]$Text,[string]$Pattern)
    $m=@(Get-TopLevelMatches $Text $Pattern)
    if($m.Count){return $m[0]}
    return $null
}

function Split-TopLevelByComma {
    param([string]$Text)
    $r=New-Object System.Collections.Generic.List[string]
    $d=0; $s=0
    for($i=0;$i -lt $Text.Length;$i++){
        if($Text[$i] -eq '('){$d++}
        elseif($Text[$i] -eq ')'){if($d -gt 0){$d--}}
        elseif($Text[$i] -eq ',' -and $d -eq 0){
            $x=Normalize-Space $Text.Substring($s,$i-$s)
            if($x){$r.Add($x)}
            $s=$i+1
        }
    }
    $last=Normalize-Space $Text.Substring($s)
    if($last){$r.Add($last)}
    return $r
}

function Split-TopLevelLogical {
    param([string]$Text)
    $r=New-Object System.Collections.Generic.List[string]
    $d=0; $s=0; $skipBetween=$false; $i=0
    while($i -lt $Text.Length){
        if($Text[$i] -eq '('){$d++;$i++;continue}
        if($Text[$i] -eq ')'){if($d -gt 0){$d--};$i++;continue}
        if($d -eq 0){
            $rest=$Text.Substring($i)
            if($rest -match '^(?i)\bBETWEEN\b'){ $skipBetween=$true; $i += $matches[0].Length; continue }
            $m=[regex]::Match($rest,'^(AND|OR)\b',[System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
            if($m.Success){
                if($m.Groups[1].Value.ToUpperInvariant() -eq 'AND' -and $skipBetween){$skipBetween=$false;$i+=$m.Length;continue}
                if($i -gt $s){$seg=Normalize-Space $Text.Substring($s,$i-$s); if($seg){$r.Add($seg)}}
                $s=$i
            }
        }
        $i++
    }
    $tail=Normalize-Space $Text.Substring($s); if($tail){$r.Add($tail)}
    if($r.Count -eq 0){$r.Add((Normalize-Space $Text))}
    return $r
}

function Add-IndentedLines {
    param([System.Collections.Generic.List[string]]$Out,[string[]]$Lines,[int]$Indent)
    $p=' '*$Indent
    foreach($l in $Lines){
        if([string]::IsNullOrWhiteSpace($l)){$Out.Add("")}
        else{$Out.Add($p+$l.TrimEnd())}
    }
}

function Format-CommaList {
    param([string]$Text,[string]$FirstPrefix,[string]$NextPrefix)
    $out=New-Object System.Collections.Generic.List[string]
    $items=@(Split-TopLevelByComma $Text)
    for($i=0;$i -lt $items.Count;$i++){
        $suf=if($i -lt $items.Count-1){","}else{""}
        if($i -eq 0){$out.Add($FirstPrefix+$items[$i]+$suf)}else{$out.Add($NextPrefix+$items[$i]+$suf)}
    }
    return $out
}

function Format-InlineParenCommaList {
    param([string]$Keyword,[string]$Text,[string]$Prefix)
    $out=New-Object System.Collections.Generic.List[string]
    $items=@(Split-TopLevelByComma $Text)
    $one=$Prefix+$Keyword+"( "+($items -join ', ')+" )"
    if($one.Length -le $script:MaxLineLength){$out.Add($one);return $out}
    $cont=' '*($Keyword.Length+2)
    for($i=0;$i -lt $items.Count;$i++){
        $suf=if($i -lt $items.Count-1){","}else{" )"}
        if($i -eq 0){$out.Add($Prefix+$Keyword+"( "+$items[$i]+$suf)}
        else{$out.Add($Prefix+$cont+$items[$i]+$suf)}
    }
    return $out
}

function Format-NestedSelectExpression {
    param([string]$Head,[string]$InnerSql,[string]$Tail,[int]$Indent,[int]$SubqueryDepth)
    $inner=$InnerSql.Trim()
    if($inner -notmatch '^\s*(SELECT|WITH)\b' -or $SubqueryDepth -ge 3){ return $Head+"("+(Normalize-Space $InnerSql)+")"+$Tail }
    # The nested SELECT starts after the text before the parenthesis.
    # Example:
    #   AND EXISTS (SELECT ...
    #               FROM ...
    $nestedIndent = $Indent + $Head.Length + 1
    $lines=@(Format-SqlStatement -Statement $inner -Indent $nestedIndent -NoSemicolon -SubqueryDepth ($SubqueryDepth+1))
    if($lines.Count -eq 0){return $Head+"()"}
    $out=New-Object System.Collections.Generic.List[string]
    $out.Add($Head+"("+$lines[0].Trim())
    for($i=1;$i -lt $lines.Count;$i++){$out.Add($lines[$i])}
    $out[$out.Count-1]=$out[$out.Count-1].TrimEnd()+")"+$Tail
    return ($out -join [Environment]::NewLine)
}

function Format-FirstParenthesizedSelectInText {
    param([string]$Text, [int]$Indent, [int]$SubqueryDepth = 0)

    $work = Normalize-Space $Text

    # Only bother when there is a nested SELECT/WITH.
    if ($work -notmatch '\(\s*(SELECT|WITH)\b') {
        return $work
    }

    # Keep short nested subqueries on one line.
    if (($work.Length + $Indent) -le $script:MaxLineLength) {
        return $work
    }

    for ($i = 0; $i -lt $work.Length; $i++) {
        if ($work[$i] -ne '(') { continue }

        $close = Find-MatchingParen $work $i
        if ($close -lt 0) { continue }

        $inner = $work.Substring($i + 1, $close - $i - 1).Trim()
        if ($inner -notmatch '^\s*(SELECT|WITH)\b') { continue }

        $head = $work.Substring(0, $i)
        $tail = $work.Substring($close + 1)

        return Format-NestedSelectExpression `
            -Head $head `
            -InnerSql $inner `
            -Tail $tail `
            -Indent $Indent `
            -SubqueryDepth $SubqueryDepth
    }

    return $work
}

function Format-CaseExpression {
    param([string]$Item,[string]$FirstPrefix,[string]$NextPrefix)
    $out=New-Object System.Collections.Generic.List[string]
    $item=Normalize-Space $Item
    if($item -notmatch '^\s*CASE\b'){$out.Add($FirstPrefix+$item);return $out}
    $alias=""; $body=$item
    $am=[regex]::Match($item,'\bEND\s+AS\s+([A-Z0-9_"]+)\s*$','IgnoreCase')
    if($am.Success){$alias=" AS "+$am.Groups[1].Value; $body=$item.Substring(0,$am.Index+3).Trim()}
    $out.Add($FirstPrefix+"CASE")
    $work=$body -replace '^\s*CASE\s+',''
    $work=$work -replace '\s*END\s*$',''
    $tok=[regex]::Matches($work,'\bWHEN\b|\bELSE\b',[System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if($tok.Count -eq 0){$out[0]=$FirstPrefix+$item;return $out}
    for($i=0;$i -lt $tok.Count;$i++){
        $n=if($i -lt $tok.Count-1){$tok[$i+1].Index}else{$work.Length}
        $seg=Normalize-Space $work.Substring($tok[$i].Index,$n-$tok[$i].Index)
        $seg=Format-FirstParenthesizedSelectInText $seg ($NextPrefix.Length+2) 0
        if(
            ($seg -match [regex]::Escape([Environment]::NewLine) -and $seg -match '^(WHEN\s+[\s\S]+?)\s+THEN\s+([\s\S]+)$') -or
            (($NextPrefix+"  "+$seg).Length -gt $script:MaxLineLength -and $seg -match '^(WHEN\s+.+?)\s+THEN\s+(.+)$')
        ){
            $out.Add($NextPrefix+"  "+$matches[1])
            $out.Add($NextPrefix+"  THEN "+$matches[2])
        } else {
            $out.Add($NextPrefix+"  "+$seg)
        }
    }
    $out.Add($NextPrefix+"END"+$alias)
    return $out
}

function Format-WindowExpression {
    param([string]$Item,[string]$FirstPrefix,[string]$NextPrefix)
    $out=New-Object System.Collections.Generic.List[string]
    $item=Normalize-Space $Item
    $m=[regex]::Match($item,'^(.*?)\s+OVER\s*\((.*)\)(\s+AS\s+[A-Z0-9_"]+)?$',[System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if(-not $m.Success){$out.Add($FirstPrefix+$item);return $out}
    $func=Normalize-Space $m.Groups[1].Value
    $inside=Normalize-Space $m.Groups[2].Value
    $alias=$m.Groups[3].Value
    $out.Add($FirstPrefix+$func)
    $pm=[regex]::Match($inside,'^(PARTITION\s+BY\s+.*?)(\s+ORDER\s+BY\s+.*)?$',[System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if($pm.Success){
        $partition=Normalize-Space $pm.Groups[1].Value
        $order=Normalize-Space $pm.Groups[2].Value
        $out.Add($NextPrefix+"  OVER ("+$partition)
        if($order.Length -gt 0){$out.Add($NextPrefix+"      "+$order+")"+$alias)}
        else{$out.Add($NextPrefix+"  )"+$alias)}
    } else {
        $out.Add($NextPrefix+"  OVER ("+$inside+")"+$alias)
    }
    return $out
}

function Format-SelectList {
    param([string]$Text,[int]$Indent,[int]$SubqueryDepth=0)
    $out=New-Object System.Collections.Generic.List[string]
    $items=@(Split-TopLevelByComma (Normalize-Space $Text))
    $compact="SELECT "+($items -join ', ')
    if($items.Count -le 3 -and ($compact.Length+$Indent) -le $script:MaxLineLength){$out.Add((' '*$Indent)+$compact);return $out}
    $fp=(' '*$Indent)+"SELECT "; $np=(' '*$Indent)+"       "
    for($i=0;$i -lt $items.Count;$i++){
        $suf=if($i -lt $items.Count-1){","}else{""}
        $p=if($i -eq 0){$fp}else{$np}
        $item=Format-FirstParenthesizedSelectInText $items[$i] ($Indent+7) $SubqueryDepth
        if($item -match '^\s*CASE\b'){
            $lines=@(Format-CaseExpression $item $p $np)
            for($j=0;$j -lt $lines.Count;$j++){if($j -eq $lines.Count-1){$out.Add($lines[$j]+$suf)}else{$out.Add($lines[$j])}}
        } elseif($item -match '\bOVER\s*\('){
            $lines=@(Format-WindowExpression $item $p $np)
            for($j=0;$j -lt $lines.Count;$j++){if($j -eq $lines.Count-1){$out.Add($lines[$j]+$suf)}else{$out.Add($lines[$j])}}
        } elseif($item -match [regex]::Escape([Environment]::NewLine)) {
            $lines=$item -split [regex]::Escape([Environment]::NewLine)
            for($j=0;$j -lt $lines.Count;$j++){if($j -eq 0){$out.Add($p+$lines[$j])}elseif($j -eq $lines.Count-1){$out.Add($lines[$j]+$suf)}else{$out.Add($lines[$j])}}
        } else {
            $out.Add($p+$item+$suf)
        }
    }
    return $out
}

function Format-LogicalGroupIfNeeded {
    param([string]$Condition,[string]$LinePrefix)
    $work=Normalize-Space $Condition
    if($work -notmatch '^\((.+)\)$'){return $work}
    if(($LinePrefix+$work).Length -le $script:MaxLineLength){return $work}
    $inner=$work.Substring(1,$work.Length-2).Trim()
    $parts=@(Split-TopLevelLogical $inner)
    if($parts.Count -le 1){return $work}
    $out=New-Object System.Collections.Generic.List[string]
    for($i=0;$i -lt $parts.Count;$i++){
        $raw=Normalize-Space $parts[$i]
        $op=""; $conditionText=$raw
        if($raw -match '^(AND|OR)\s+(.+)$'){$op=$matches[1].ToUpperInvariant();$conditionText=$matches[2]}
        if($i -eq 0){$out.Add("(   "+$conditionText)}
        elseif($op -eq "OR"){$out.Add("        OR "+$conditionText)}
        else{$out.Add("       AND "+$conditionText)}
    }
    $out[$out.Count-1]=$out[$out.Count-1]+")"
    return ($out -join [Environment]::NewLine)
}

function Format-WhereClause {
    param([string]$Text,[string]$Keyword,[int]$Indent,[int]$SubqueryDepth=0)
    $out=New-Object System.Collections.Generic.List[string]
    $p=' '*$Indent
    $parts=@(Split-TopLevelLogical $Text)
    for($i=0;$i -lt $parts.Count;$i++){
        $rawPart=Normalize-Space $parts[$i]
        $op=""; $condition=$rawPart
        if($rawPart -match '^(AND|OR)\s+(.+)$'){$op=$matches[1].ToUpperInvariant();$condition=$matches[2]}
        $conditionColumn=$Indent+7
        $condition=Format-FirstParenthesizedSelectInText (Normalize-Space $condition) $conditionColumn $SubqueryDepth
        $linePrefix=if($i -eq 0){$p+$Keyword+" "}elseif($op -eq "OR"){$p+"    OR "}else{$p+"   AND "}
        $condition=Format-LogicalGroupIfNeeded $condition $linePrefix
        if($i -eq 0){$out.Add($p+$Keyword+" "+$condition)}
        elseif($op -eq "OR"){$out.Add($p+"    OR "+$condition)}
        else{$out.Add($p+"   AND "+$condition)}
    }
    return $out
}

function Format-JoinClause {
    param([string]$JoinText,[string]$Prefix,[int]$JoinPad)
    $out=New-Object System.Collections.Generic.List[string]
    $jt=Normalize-Space $JoinText
    if(($Prefix+(' '*$JoinPad)+$jt).Length -le $script:MaxLineLength){$out.Add($Prefix+(' '*$JoinPad)+$jt);return $out}
    $on=Get-FirstTopLevelMatch $jt '\bON\b'
    if($null -eq $on){$out.Add($Prefix+(' '*$JoinPad)+$jt);return $out}
    $head=Normalize-Space $jt.Substring(0,$on.Index)
    $cond=Normalize-Space $jt.Substring($on.Index+$on.Length)
    $out.Add($Prefix+(' '*$JoinPad)+$head)
    $parts=@(Split-TopLevelLogical $cond)
    for($i=0;$i -lt $parts.Count;$i++){
        $raw=Normalize-Space $parts[$i]
        $op=""; $condition=$raw
        if($raw -match '^(AND|OR)\s+(.+)$'){$op=$matches[1].ToUpperInvariant();$condition=$matches[2]}
        if($i -eq 0){$out.Add($Prefix+"    ON "+$condition)}
        elseif($op -eq "OR"){$out.Add($Prefix+"    OR "+$condition)}
        else{$out.Add($Prefix+"   AND "+$condition)}
    }
    return $out
}

function Format-FromClause {
    param([string]$Text,[int]$Indent,[int]$SubqueryDepth=0)
    $out=New-Object System.Collections.Generic.List[string]
    $p=' '*$Indent; $t=$Text.Trim()
    if($t.StartsWith("(")){
        $close=Find-MatchingParen $t 0
        if($close -gt 0){
            $inner=$t.Substring(1,$close-1).Trim(); $alias=Normalize-Space $t.Substring($close+1)
            if($inner -match '^\s*(SELECT|WITH)\b'){
                $lines=@(Format-SqlStatement $inner ($Indent+9) -NoSemicolon -SubqueryDepth ($SubqueryDepth+1))
                $out.Add($p+"  FROM ( "+$lines[0].Trim())
                for($i=1;$i -lt $lines.Count;$i++){$out.Add($lines[$i])}
                $out[$out.Count-1]=$out[$out.Count-1].TrimEnd()+" )"+$(if($alias){" "+$alias}else{""})
                return $out
            }
        }
    }
    $jp='\b(LEFT\s+OUTER\s+JOIN|RIGHT\s+OUTER\s+JOIN|FULL\s+OUTER\s+JOIN|INNER\s+JOIN|LEFT\s+JOIN|RIGHT\s+JOIN|FULL\s+JOIN|CROSS\s+JOIN|JOIN)\b'
    $m=@(Get-TopLevelMatches $t $jp)
    if($m.Count -eq 0){$out.Add($p+"  FROM "+(Normalize-Space $t));return $out}
    $src=Normalize-Space $t.Substring(0,$m[0].Index)
    if($src){$out.Add($p+"  FROM "+$src)}
    for($i=0;$i -lt $m.Count;$i++){
        $n=if($i -lt $m.Count-1){$m[$i+1].Index}else{$t.Length}
        $jt=Normalize-Space $t.Substring($m[$i].Index,$n-$m[$i].Index)
        $fw=($jt -split '\s+',2)[0].ToUpperInvariant()
        $pad=[Math]::Max(1,6-$fw.Length)
        Add-IndentedLines $out @(Format-JoinClause $jt $p $pad) 0
    }
    return $out
}

function Has-TopLevelSetOperator { param([string]$Sql) return (@(Get-TopLevelMatches $Sql '\b(UNION\s+ALL|UNION|EXCEPT|INTERSECT)\b').Count -gt 0) }

function Format-SetQuery {
    param([string]$Sql,[int]$Indent=0,[switch]$NoSemicolon,[int]$SubqueryDepth=0)
    $out=New-Object System.Collections.Generic.List[string]
    $m=@(Get-TopLevelMatches $Sql '\b(UNION\s+ALL|UNION|EXCEPT|INTERSECT)\b')
    $s=0
    for($i=0;$i -lt $m.Count;$i++){
        $part=$Sql.Substring($s,$m[$i].Index-$s).Trim()
        if($part){Add-IndentedLines $out @(Format-SqlStatement $part $Indent -NoSemicolon -SubqueryDepth $SubqueryDepth) 0}
        $out.Add((' '*$Indent)+$m[$i].Value.ToUpperInvariant())
        $s=$m[$i].Index+$m[$i].Length
    }
    $tail=$Sql.Substring($s).Trim()
    if($tail){Add-IndentedLines $out @(Format-SqlStatement $tail $Indent -NoSemicolon:$NoSemicolon -SubqueryDepth $SubqueryDepth) 0}
    return $out
}

function Get-SelectClauses {
    param([string]$Sql)
    $pat='\bFROM\b|\bWHERE\b|\bGROUP\s+BY\b|\bHAVING\b|\bORDER\s+BY\b|\bFETCH\s+FIRST\b|\bLIMIT\b|\bOPTIMIZE\s+FOR\b|\bFOR\s+UPDATE\b|\bWITH\s+(UR|RS|CS|RR|NC)\b'
    $m=@(Get-TopLevelMatches $Sql $pat)
    $r=New-Object System.Collections.Generic.List[object]
    for($i=0;$i -lt $m.Count;$i++){
        $n=if($i -lt $m.Count-1){$m[$i+1].Index}else{$Sql.Length}
        $r.Add([pscustomobject]@{Name=$m[$i].Value.ToUpperInvariant();Index=$m[$i].Index;Length=$m[$i].Length;Text=$Sql.Substring($m[$i].Index+$m[$i].Length,$n-($m[$i].Index+$m[$i].Length)).Trim()})
    }
    return $r
}

function Format-SelectStatement {
    param([string]$Sql,[int]$Indent=0,[switch]$NoSemicolon,[int]$SubqueryDepth=0)
    $Sql=Normalize-Space (Strip-TrailingSemicolon $Sql)
    if(Has-TopLevelSetOperator $Sql){return Format-SetQuery $Sql $Indent -NoSemicolon:$NoSemicolon -SubqueryDepth $SubqueryDepth}
    $out=New-Object System.Collections.Generic.List[string]; $p=' '*$Indent
    if($Sql -notmatch '^\s*SELECT\b'){$out.Add($p+$Sql);return $out}
    $cl=@(Get-SelectClauses $Sql)
    if($cl.Count -eq 0){Add-IndentedLines $out @(Format-SelectList ($Sql -replace '^\s*SELECT\s+','') $Indent $SubqueryDepth) 0;return $out}
    $sel=$Sql.Substring(6,$cl[0].Index-6).Trim()
    Add-IndentedLines $out @(Format-SelectList $sel $Indent $SubqueryDepth) 0
    foreach($c in $cl){
        $n=$c.Name; $tx=$c.Text
        if($n -eq 'FROM'){Add-IndentedLines $out @(Format-FromClause $tx $Indent $SubqueryDepth) 0}
        elseif($n -eq 'WHERE'){Add-IndentedLines $out @(Format-WhereClause $tx " WHERE" $Indent $SubqueryDepth) 0}
        elseif($n -eq 'GROUP BY'){if(($p+" GROUP BY "+(Normalize-Space $tx)).Length -le $script:MaxLineLength){$out.Add($p+" GROUP BY "+(Normalize-Space $tx))}else{Add-IndentedLines $out @(Format-CommaList $tx ($p+" GROUP BY ") ($p+"          ")) 0}}
        elseif($n -eq 'HAVING'){Add-IndentedLines $out @(Format-WhereClause $tx "HAVING" $Indent $SubqueryDepth) 0}
        elseif($n -eq 'ORDER BY'){if(($p+" ORDER BY "+(Normalize-Space $tx)).Length -le $script:MaxLineLength){$out.Add($p+" ORDER BY "+(Normalize-Space $tx))}else{Add-IndentedLines $out @(Format-CommaList $tx ($p+" ORDER BY ") ($p+"          ")) 0}}
        elseif($n -eq 'FETCH FIRST'){$out.Add($p+" FETCH FIRST "+(Normalize-Space $tx))}
        elseif($n -eq 'LIMIT'){$out.Add($p+" LIMIT "+(Normalize-Space $tx))}
        elseif($n -eq 'OPTIMIZE FOR'){$out.Add($p+" OPTIMIZE FOR "+(Normalize-Space $tx))}
        elseif($n -eq 'FOR UPDATE'){$out.Add($p+" FOR UPDATE "+(Normalize-Space $tx))}
        elseif($n -match '^WITH\s+'){$out.Add($p+"  "+$n)}
    }
    return $out
}

function Format-WithStatement {
    param([string]$Sql,[int]$Indent=0,[switch]$NoSemicolon,[int]$SubqueryDepth=0)
    $Sql=Normalize-Space (Strip-TrailingSemicolon $Sql)
    $p=' '*$Indent; $out=New-Object System.Collections.Generic.List[string]
    $body=$Sql -replace '^\s*WITH\s+',''
    $pos=0; $idx=0
    while($pos -lt $body.Length){
        $rem=$body.Substring($pos)
        $m=[regex]::Match($rem,'^\s*([A-Z0-9_]+(?:\s*\([^)]*\))?)\s+AS\s*\(',[System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if(-not $m.Success){break}
        $name=Normalize-Space $m.Groups[1].Value
        $open=$pos+$m.Index+$m.Length-1
        $close=Find-MatchingParen $body $open
        if($close -lt 0){break}
        $inner=$body.Substring($open+1,$close-$open-1).Trim()
        # The inner SELECT is printed after:
        #   "     AS ( "
        # That prefix is 10 characters after the current CTE indent.
        # So the inner SELECT formatter must use that same local starting column.
        $lines = @(Format-SqlStatement $inner ($Indent + 10) -NoSemicolon -SubqueryDepth ($SubqueryDepth + 1))
        if($idx -eq 0){$out.Add($p+"WITH "+$name)}else{$out.Add($p+"     "+$name)}
        $out.Add($p+"     AS ( "+$lines[0].Trim())
        for($i=1;$i -lt $lines.Count;$i++){$out.Add($lines[$i])}
        $pos=$close+1
        while($pos -lt $body.Length -and [char]::IsWhiteSpace($body[$pos])){$pos++}
        $out[$out.Count-1]=$out[$out.Count-1].TrimEnd()+" )"
        if($pos -lt $body.Length -and $body[$pos] -eq ','){$out[$out.Count-1]+=",";$pos++;$idx++}else{break}
    }
    $rest=$body.Substring($pos).Trim()
    if($out.Count -eq 0){$out.Add($p+$Sql);return $out}
    if($rest){Add-IndentedLines $out @(Format-SqlStatement $rest $Indent -NoSemicolon -SubqueryDepth $SubqueryDepth) 0}
    return $out
}

function Format-InsertStatement {
    param([string]$Sql,[int]$Indent=0,[switch]$NoSemicolon,[int]$SubqueryDepth=0)
    $Sql=Normalize-Space (Strip-TrailingSemicolon $Sql); $p=' '*$Indent; $out=New-Object System.Collections.Generic.List[string]
    $sel=Get-FirstTopLevelMatch $Sql '\b(WITH|SELECT)\b'; $val=Get-FirstTopLevelMatch $Sql '\bVALUES\b'
    if($null -ne $sel -and ($null -eq $val -or $sel.Index -lt $val.Index)){
        $head=$Sql.Substring(0,$sel.Index).Trim(); $query=$Sql.Substring($sel.Index).Trim()
        $o=$head.IndexOf('('); $c=if($o -ge 0){Find-MatchingParen $head $o}else{-1}
        if($o -ge 0 -and $c -gt $o){Add-IndentedLines $out @(Format-InlineParenCommaList ((Normalize-Space $head.Substring(0,$o))+" ") $head.Substring($o+1,$c-$o-1) $p) 0}else{$out.Add($p+$head)}
        Add-IndentedLines $out @(Format-SqlStatement $query $Indent -NoSemicolon -SubqueryDepth $SubqueryDepth) 0
        return $out
    }
    if($null -ne $val){
        $head=$Sql.Substring(0,$val.Index).Trim(); $values=$Sql.Substring($val.Index+$val.Length).Trim()
        $o=$head.IndexOf('('); $c=if($o -ge 0){Find-MatchingParen $head $o}else{-1}
        if($o -ge 0 -and $c -gt $o){Add-IndentedLines $out @(Format-InlineParenCommaList ((Normalize-Space $head.Substring(0,$o))+" ") $head.Substring($o+1,$c-$o-1) $p) 0}else{$out.Add($p+$head)}
        if($values.StartsWith("(")){ $e=Find-MatchingParen $values 0; if($e -gt 0){Add-IndentedLines $out @(Format-InlineParenCommaList "VALUES " $values.Substring(1,$e-1) $p) 0; return $out}}
    }
    $out.Add($p+$Sql); return $out
}

function Format-UpdateStatement {
    param([string]$Sql,[int]$Indent=0,[int]$SubqueryDepth=0)
    $Sql=Normalize-Space (Strip-TrailingSemicolon $Sql); $p=' '*$Indent; $out=New-Object System.Collections.Generic.List[string]
    $set=Get-FirstTopLevelMatch $Sql '\bSET\b'; if($null -eq $set){$out.Add($p+$Sql);return $out}
    $where=Get-FirstTopLevelMatch $Sql '\bWHERE\b'; $head=Normalize-Space $Sql.Substring(0,$set.Index)
    $end=if($null -ne $where){$where.Index}else{$Sql.Length}
    $setText=$Sql.Substring($set.Index+$set.Length,$end-($set.Index+$set.Length)).Trim()
    $out.Add($p+$head)
    $items=@(Split-TopLevelByComma $setText)
    for($i=0;$i -lt $items.Count;$i++){
        $suf=if($i -lt $items.Count-1){","}else{""}
        $pref=if($i -eq 0){$p+"   SET "}else{$p+"       "}
        $a=Format-FirstParenthesizedSelectInText (Normalize-Space $items[$i]) ($Indent+7) $SubqueryDepth
        $cm=[regex]::Match($a,'^(.*?)=\s*(CASE\b[\s\S]+\bEND)$',[System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if($cm.Success){
            $left=Normalize-Space $cm.Groups[1].Value; $case=$cm.Groups[2].Value
            $cp=$pref+$left+" = "; $np=' '*$cp.Length
            $ls=@(Format-CaseExpression $case $cp $np); $ls[$ls.Count-1]+=$suf
            Add-IndentedLines $out $ls 0
        } elseif($a -match [regex]::Escape([Environment]::NewLine)){
            $ls=$a -split [regex]::Escape([Environment]::NewLine)
            for($j=0;$j -lt $ls.Count;$j++){
                if($j -eq 0){$out.Add($pref+$ls[$j])}
                elseif($j -eq $ls.Count-1){$out.Add($ls[$j]+$suf)}
                else{$out.Add($ls[$j])}
            }
        } else {
            $out.Add($pref+$a+$suf)
        }
    }
    if($null -ne $where){Add-IndentedLines $out @(Format-WhereClause $Sql.Substring($where.Index+$where.Length).Trim() " WHERE" $Indent $SubqueryDepth) 0}
    return $out
}

function Format-DeleteStatement {
    param([string]$Sql,[int]$Indent=0,[int]$SubqueryDepth=0)
    $Sql=Normalize-Space (Strip-TrailingSemicolon $Sql); $p=' '*$Indent; $out=New-Object System.Collections.Generic.List[string]
    $w=Get-FirstTopLevelMatch $Sql '\bWHERE\b'
    if($Sql -match '^\s*DELETE\s+FROM\b' -and $null -ne $w){
        $out.Add($p+"DELETE")
        $out.Add($p+"  FROM "+(Normalize-Space ($Sql.Substring(0,$w.Index) -replace '^\s*DELETE\s+FROM\s+','')))
        Add-IndentedLines $out @(Format-WhereClause $Sql.Substring($w.Index+$w.Length).Trim() " WHERE" $Indent $SubqueryDepth) 0
        return $out
    }
    if($null -eq $w){$out.Add($p+$Sql);return $out}
    $out.Add($p+(Normalize-Space $Sql.Substring(0,$w.Index)))
    Add-IndentedLines $out @(Format-WhereClause $Sql.Substring($w.Index+$w.Length).Trim() " WHERE" $Indent $SubqueryDepth) 0
    return $out
}

function Format-MergeStatement {
    param([string]$Sql,[int]$Indent=0,[int]$SubqueryDepth=0)
    $Sql=Normalize-Space (Strip-TrailingSemicolon $Sql); $p=' '*$Indent; $out=New-Object System.Collections.Generic.List[string]
    $using=Get-FirstTopLevelMatch $Sql '\bUSING\b'; $on=Get-FirstTopLevelMatch $Sql '\bON\b'; $whens=@(Get-TopLevelMatches $Sql '\bWHEN\s+(MATCHED|NOT\s+MATCHED)\s+THEN\b')
    if($null -eq $using -or $null -eq $on){$out.Add($p+$Sql);return $out}
    $out.Add($p+" MERGE "+(Normalize-Space (($Sql.Substring(0,$using.Index)) -replace '^\s*MERGE\s+','')))
    $ub=$Sql.Substring($using.Index+$using.Length,$on.Index-($using.Index+$using.Length)).Trim()
    if($ub.StartsWith("(")){
        $c=Find-MatchingParen $ub 0
        $inner=$ub.Substring(1,$c-1).Trim(); $alias=Normalize-Space $ub.Substring($c+1)
        $lines=@(Format-SqlStatement $inner ($Indent+9) -NoSemicolon -SubqueryDepth ($SubqueryDepth+1))
        $out.Add($p+" USING ( "+$lines[0].Trim())
        for($i=1;$i -lt $lines.Count;$i++){$out.Add($lines[$i])}
        $out[$out.Count-1]=$out[$out.Count-1].TrimEnd()+" )"+$(if($alias){" "+$alias}else{""})
    } else {
        $out.Add($p+" USING "+$ub)
    }
    $onEnd=if($whens.Count){$whens[0].Index}else{$Sql.Length}
    $parts=@(Split-TopLevelLogical $Sql.Substring($on.Index+$on.Length,$onEnd-($on.Index+$on.Length)))
    for($i=0;$i -lt $parts.Count;$i++){
        $raw=Normalize-Space $parts[$i]; $op=""; $condition=$raw
        if($raw -match '^(AND|OR)\s+(.+)$'){$op=$matches[1].ToUpperInvariant();$condition=$matches[2]}
        if($i -eq 0){$out.Add($p+"    ON "+$condition)}
        elseif($op -eq "OR"){$out.Add($p+"    OR "+$condition)}
        else{$out.Add($p+"   AND "+$condition)}
    }
    for($i=0;$i -lt $whens.Count;$i++){
        $n=if($i -lt $whens.Count-1){$whens[$i+1].Index}else{$Sql.Length}
        $wt=Normalize-Space $Sql.Substring($whens[$i].Index,$n-$whens[$i].Index)
        $up=[regex]::Match($wt,'^(WHEN\s+MATCHED\s+THEN)\s+UPDATE\s+SET\s+(.+)$','IgnoreCase')
        $ins=[regex]::Match($wt,'^(WHEN\s+NOT\s+MATCHED\s+THEN)\s+INSERT\s*\((.+?)\)\s+VALUES\s*\((.+)\)$','IgnoreCase')
        if($up.Success){$out.Add($p+"  WHEN MATCHED THEN"); Add-IndentedLines $out @(Format-CommaList $up.Groups[2].Value ($p+"UPDATE SET ") ($p+"           ")) 0}
        elseif($ins.Success){$out.Add($p+"  WHEN NOT MATCHED THEN"); Add-IndentedLines $out @(Format-InlineParenCommaList "INSERT " $ins.Groups[2].Value $p) 0; Add-IndentedLines $out @(Format-InlineParenCommaList "VALUES " $ins.Groups[3].Value $p) 0}
        else{$out.Add($p+"  "+$wt)}
    }
    return $out
}

function Format-CreateTableStatement {
    param([string]$Sql,[int]$Indent=0)
    $Sql=Normalize-Space (Strip-TrailingSemicolon $Sql); $p=' '*$Indent; $out=New-Object System.Collections.Generic.List[string]
    $o=$Sql.IndexOf('('); if($o -lt 0){$out.Add($p+$Sql);return $out}
    $c=Find-MatchingParen $Sql $o; if($c -lt 0){$out.Add($p+$Sql);return $out}
    $head=Normalize-Space $Sql.Substring(0,$o); $body=$Sql.Substring($o+1,$c-$o-1); $tail=Normalize-Space $Sql.Substring($c+1)
    $out.Add($p+$head+" (")
    Add-IndentedLines $out @(Format-CommaList $body ($p+"  ") ($p+"  ")) 0
    $out.Add($p+")"+$(if($tail){" "+$tail}else{""}))
    return $out
}

function Format-CreateTableAsStatement {
    param([string]$Sql,[int]$Indent=0,[int]$SubqueryDepth=0)
    $Sql=Normalize-Space (Strip-TrailingSemicolon $Sql); $p=' '*$Indent; $out=New-Object System.Collections.Generic.List[string]
    $as=Get-FirstTopLevelMatch $Sql '\bAS\s*\('; if($null -eq $as){$out.Add($p+$Sql);return $out}
    $o=$Sql.IndexOf('(',$as.Index); $c=Find-MatchingParen $Sql $o
    $head=Normalize-Space $Sql.Substring(0,$o); $inner=$Sql.Substring($o+1,$c-$o-1); $tail=Normalize-Space $Sql.Substring($c+1)
    $out.Add($p+$head+" (")
    Add-IndentedLines $out @(Format-SqlStatement $inner ($Indent+2) -NoSemicolon -SubqueryDepth ($SubqueryDepth+1)) 0
    $out.Add($p+")")
    if($tail){$out.Add($p+$tail)}
    return $out
}

function Format-CreateViewStatement {
    param([string]$Sql,[int]$Indent=0,[int]$SubqueryDepth=0)
    $Sql=Normalize-Space (Strip-TrailingSemicolon $Sql); $p=' '*$Indent; $out=New-Object System.Collections.Generic.List[string]
    $as=Get-FirstTopLevelMatch $Sql '\bAS\b'; if($null -eq $as){$out.Add($p+$Sql);return $out}
    $out.Add($p+(Normalize-Space $Sql.Substring(0,$as.Index)))
    $out.Add($p+"AS")
    Add-IndentedLines $out @(Format-SqlStatement ($Sql.Substring($as.Index+$as.Length).Trim()) ($Indent+2) -NoSemicolon -SubqueryDepth ($SubqueryDepth+1)) 0
    return $out
}

function Format-GenericStatement {
    param([string]$Sql,[int]$Indent=0)
    $Sql=Normalize-Space (Strip-TrailingSemicolon $Sql); $p=' '*$Indent
    if(($p+$Sql).Length -le $script:MaxLineLength){return @($p+$Sql)}
    $Sql=[regex]::Replace($Sql,'\s+\b(FROM|WHERE|GROUP\s+BY|HAVING|ORDER\s+BY|FETCH\s+FIRST|WITH\s+(UR|RS|CS|RR|NC)|VALUES|SET|ON\s+COMMIT|NOT\s+LOGGED)\b',"`n`$1",'IgnoreCase')
    return @($Sql -split "`n" | ForEach-Object { $p+(Normalize-Space $_) })
}

function Format-RoutineStatement {
    param([string]$Sql,[int]$Indent=0,[int]$SubqueryDepth=0)
    $Sql=Normalize-Space (Strip-TrailingSemicolon $Sql); $p=' '*$Indent; $out=New-Object System.Collections.Generic.List[string]
    $b=Get-FirstTopLevelMatch $Sql '\bBEGIN(\s+ATOMIC)?\b'
    if($null -eq $b){$out.Add($p+$Sql);return $out}
    $head=Normalize-Space $Sql.Substring(0,$b.Index); $begin=Normalize-Space $b.Value
    $body=Normalize-Space $Sql.Substring($b.Index+$b.Length); $body=$body -replace '\bEND\s*$',''
    $o=$head.IndexOf('('); $c=if($o -ge 0){Find-MatchingParen $head $o}else{-1}
    if($o -ge 0 -and $c -gt $o){
        $out.Add($p+(Normalize-Space $head.Substring(0,$o))+" (")
        Add-IndentedLines $out @(Format-CommaList $head.Substring($o+1,$c-$o-1) ($p+"  ") ($p+"  ")) 0
        $out.Add($p+")")
        $after=Normalize-Space $head.Substring($c+1)
        if($after){foreach($part in ([regex]::Split($after,'\s+(?=LANGUAGE|RETURNS|DETERMINISTIC|NO\s+EXTERNAL\s+ACTION)') | Where-Object { $_.Trim() })){ $out.Add($p+(Normalize-Space $part))}}
    } else {
        $out.Add($p+$head)
    }
    $out.Add($p+$begin)
    Add-IndentedLines $out @(Format-RoutineBody $body ($Indent+2) $SubqueryDepth) 0
    $out.Add($p+"END")
    return $out
}

function Format-RoutineBody {
    param([string]$Body,[int]$Indent,[int]$SubqueryDepth=0)
    $Body=Normalize-Space $Body
    $Body=[regex]::Replace($Body,'\s+\b(DECLARE|OPEN|FETCH|CLOSE|PREPARE|EXECUTE|IF|END IF|LOOP|END LOOP|LEAVE|SIGNAL|RETURN|MERGE INTO|SELECT|WITH|UPDATE|DELETE|INSERT)\b',"`n`$1",'IgnoreCase')
    $Body=[regex]::Replace($Body,';\s*',";`n")
    $raw=$Body -split "`n" | Where-Object { $_.Trim() }
    $out=New-Object System.Collections.Generic.List[string]
    $level=0
    foreach($r in $raw){
        $line=Normalize-Space $r; $semi=$line.EndsWith(";"); $line=$line -replace ';\s*$',''
        if($line -match '^(END IF|END LOOP|END)\b' -and $level -gt 0){$level--}
        $ind=$Indent+($level*2)
        if($line -match '^(SELECT|WITH|MERGE INTO|UPDATE|DELETE|INSERT)\b'){
            Add-IndentedLines $out @(Format-SqlStatement $line $ind -NoSemicolon -SubqueryDepth $SubqueryDepth) 0
            if($semi -and $out.Count){$out[$out.Count-1]=$out[$out.Count-1].TrimEnd()+";"}
        } else {
            $out.Add((' '*$ind)+$line+$(if($semi){";"}else{""}))
        }
        if($line -match '\b(THEN|LOOP)\b' -and $line -notmatch '^END'){$level++}
        if($semi){$out.Add("")}
    }
    while($out.Count -gt 0 -and [string]::IsNullOrWhiteSpace($out[$out.Count-1])){$out.RemoveAt($out.Count-1)}
    return $out
}

function Remove-LeadingProtectedCommentsForDetection {
    param([string]$Text)
    $w=$Text.Trim()
    while($w -match '^\s*__SQLFMT_(LCOM|BCOM)_\d+__\s*'){
        $w=[regex]::Replace($w,'^\s*__SQLFMT_(LCOM|BCOM)_\d+__\s*','').Trim()
    }
    return $w
}

function Test-RoutineStatementComplete {
    param([string]$Text)
    $w=(Remove-LeadingProtectedCommentsForDetection $Text).ToUpperInvariant()
    if($w -notmatch '^\s*CREATE\s+(OR\s+REPLACE\s+)?(PROCEDURE|FUNCTION)\b'){return $false}
    $tok=[regex]::Matches($w,'\bBEGIN\s+ATOMIC\b|\bBEGIN\b|\bCASE\b|\bLOOP\b|\bIF\b|\bEND\s+IF\b|\bEND\s+LOOP\b|\bEND\b',[System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    $d=0
    foreach($tm in $tok){
        $t=$tm.Value.ToUpperInvariant() -replace '\s+',' '
        if($t -match '^BEGIN|^CASE$|^LOOP$|^IF$'){$d++}
        elseif($t -match '^END IF$|^END LOOP$|^END$'){if($d -gt 0){$d--}}
    }
    return ($d -eq 0 -and $w -match '\bEND\s*$')
}

function Split-SqlStatements {
    param([string]$Sql)
    $st=New-Object System.Collections.Generic.List[string]
    $d=0; $s=0; $routine=$false
    for($i=0;$i -lt $Sql.Length;$i++){
        if($Sql[$i] -eq '('){$d++}
        elseif($Sql[$i] -eq ')'){if($d -gt 0){$d--}}
        elseif($Sql[$i] -eq ';' -and $d -eq 0){
            $cand=$Sql.Substring($s,$i-$s).Trim()
            if($cand){
                $det=Remove-LeadingProtectedCommentsForDetection $cand
                if(-not $routine -and $det -match '^\s*CREATE\s+(OR\s+REPLACE\s+)?(PROCEDURE|FUNCTION)\b'){$routine=$true}
                if($routine){
                    if(-not (Test-RoutineStatementComplete $cand)){continue}
                    $routine=$false
                }
                $st.Add($cand+';')
            }
            $s=$i+1
        }
    }
    $tail=$Sql.Substring($s).Trim()
    if($tail){$st.Add($tail)}
    return $st
}

function Extract-LeadingComments {
    param([string]$Statement)
    $comments=New-Object System.Collections.Generic.List[string]
    $remaining=$Statement.Trim()
    while($remaining -match '^\s*(__SQLFMT_(LCOM|BCOM)_\d+__)\s*(.*)$'){
        $comments.Add($matches[1])
        $remaining=$matches[2].Trim()
    }
    return [pscustomobject]@{Comments=$comments;Body=$remaining}
}

function Format-SqlStatement {
    param([string]$Statement,[int]$Indent=0,[switch]$NoSemicolon,[int]$SubqueryDepth=0)
    $Statement=Convert-SqlKeywords (Normalize-Space $Statement)
    $leading=Extract-LeadingComments $Statement
    $out=New-Object System.Collections.Generic.List[string]
    foreach($c in $leading.Comments){$out.Add((' '*$Indent)+$c)}
    $body=Strip-TrailingSemicolon $leading.Body
    if(-not $body){return $out}
    $u=$body.Trim().ToUpperInvariant()
    if($u -match '^WITH\b'){Add-IndentedLines $out @(Format-WithStatement $body $Indent -NoSemicolon:$NoSemicolon -SubqueryDepth $SubqueryDepth) 0}
    elseif($u -match '^SELECT\b'){Add-IndentedLines $out @(Format-SelectStatement $body $Indent -NoSemicolon:$NoSemicolon -SubqueryDepth $SubqueryDepth) 0}
    elseif($u -match '^INSERT\b'){Add-IndentedLines $out @(Format-InsertStatement $body $Indent -NoSemicolon:$NoSemicolon -SubqueryDepth $SubqueryDepth) 0}
    elseif($u -match '^UPDATE\b'){Add-IndentedLines $out @(Format-UpdateStatement $body $Indent $SubqueryDepth) 0}
    elseif($u -match '^DELETE\b'){Add-IndentedLines $out @(Format-DeleteStatement $body $Indent $SubqueryDepth) 0}
    elseif($u -match '^MERGE\b'){Add-IndentedLines $out @(Format-MergeStatement $body $Indent $SubqueryDepth) 0}
    elseif($u -match '^CREATE\s+TABLE\b' -and $u -match '\bAS\s*\(' -and $u -match '\bWITH\s+(NO\s+)?DATA\b'){Add-IndentedLines $out @(Format-CreateTableAsStatement $body $Indent $SubqueryDepth) 0}
    elseif($u -match '^(CREATE\s+TABLE|DECLARE\s+GLOBAL\s+TEMPORARY\s+TABLE)\b'){Add-IndentedLines $out @(Format-CreateTableStatement $body $Indent) 0}
    elseif($u -match '^CREATE\s+(OR\s+REPLACE\s+)?VIEW\b'){Add-IndentedLines $out @(Format-CreateViewStatement $body $Indent $SubqueryDepth) 0}
    elseif($u -match '^CREATE\s+(OR\s+REPLACE\s+)?(PROCEDURE|FUNCTION)\b'){Add-IndentedLines $out @(Format-RoutineStatement $body $Indent $SubqueryDepth) 0}
    else{Add-IndentedLines $out @(Format-GenericStatement $body $Indent) 0}
    if(-not $NoSemicolon -and $out.Count){$out[$out.Count-1]=$out[$out.Count-1].TrimEnd()+";"}
    return $out
}

function Format-SqlText {
    param([string]$Sql)
    $protected=Convert-SqlKeywords (Protect-SqlText $Sql)
    $statements=@(Split-SqlStatements $protected)
    $all=New-Object System.Collections.Generic.List[string]
    for($i=0;$i -lt $statements.Count;$i++){
        foreach($line in @(Format-SqlStatement $statements[$i] 0)){$all.Add($line)}
        if($i -lt $statements.Count-1){$all.Add("")}
    }
    return (Restore-SqlText (($all -join [Environment]::NewLine))).TrimEnd()
}

$inputSql=[Console]::In.ReadToEnd()
[Console]::Out.Write((Format-SqlText $inputSql))