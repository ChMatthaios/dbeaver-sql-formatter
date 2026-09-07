<#
    SPARQL 1.1 formatter for the DBeaver external formatter entry point.

    Goals:
      - preserve IRIs, RDF literals, language tags and comments;
      - uppercase SPARQL keywords without touching prefixed names or literals;
      - format graph-pattern braces recursively with two-space indentation;
      - keep triple/property-list structure readable;
      - wrap at the configured maxLineLength (120 by default).
#>

$ErrorActionPreference = 'Stop'
$script:MaxLineLength = 120

$settingsPath = Join-Path $PSScriptRoot 'settings\settings.json'
if (Test-Path $settingsPath) {
    try {
        $settings = Get-Content -Path $settingsPath -Raw | ConvertFrom-Json
        if ($settings.PSObject.Properties.Name -contains 'maxLineLength') {
            $value = 0
            if ([int]::TryParse([string]$settings.maxLineLength, [ref]$value) -and $value -ge 60 -and $value -le 400) {
                $script:MaxLineLength = $value
            }
        }
    }
    catch {
        # Local settings must never break formatting.
    }
}

$script:SparqlKeywords = @{}
@(
    'BASE','PREFIX','SELECT','DISTINCT','REDUCED','AS','CONSTRUCT','WHERE','DESCRIBE','ASK',
    'FROM','NAMED','GROUP','BY','HAVING','ORDER','ASC','DESC','LIMIT','OFFSET','VALUES','UNDEF',
    'LOAD','SILENT','INTO','CLEAR','DROP','CREATE','ADD','MOVE','COPY','INSERT','DATA','DELETE',
    'WITH','USING','DEFAULT','ALL','GRAPH','OPTIONAL','SERVICE','BIND','MINUS','UNION','FILTER',
    'EXISTS','NOT','IN','TRUE','FALSE',
    'STR','LANG','LANGMATCHES','DATATYPE','BOUND','IRI','URI','BNODE','RAND','ABS','CEIL','FLOOR',
    'ROUND','CONCAT','STRLEN','UCASE','LCASE','ENCODE_FOR_URI','CONTAINS','STRSTARTS','STRENDS',
    'STRBEFORE','STRAFTER','YEAR','MONTH','DAY','HOURS','MINUTES','SECONDS','TIMEZONE','TZ','NOW',
    'UUID','STRUUID','MD5','SHA1','SHA256','SHA384','SHA512','COALESCE','IF','STRLANG','STRDT',
    'SAMETERM','ISIRI','ISURI','ISBLANK','ISLITERAL','ISNUMERIC','REGEX','SUBSTR','REPLACE',
    'COUNT','SUM','MIN','MAX','AVG','SAMPLE','GROUP_CONCAT','SEPARATOR'
) | ForEach-Object { $script:SparqlKeywords[$_] = $true }

function New-SparqlToken {
    param([string]$Type, [string]$Text)
    return [pscustomobject]@{ Type = $Type; Text = $Text }
}

function Get-SparqlTokens {
    param([string]$Text)

    $tokens = New-Object System.Collections.Generic.List[object]
    $i = 0
    while ($i -lt $Text.Length) {
        $ch = $Text[$i]

        if ([char]::IsWhiteSpace($ch)) { $i++; continue }

        # SPARQL comments run from # to end of line. IRIs are consumed before
        # this branch, so fragment identifiers inside <...#...> remain intact.
        if ($ch -eq '#') {
            $start = $i
            while ($i -lt $Text.Length -and $Text[$i] -ne "`r" -and $Text[$i] -ne "`n") { $i++ }
            $tokens.Add((New-SparqlToken -Type 'Comment' -Text $Text.Substring($start, $i - $start).TrimEnd()))
            continue
        }

        # IRIREF. A relational < operator has no matching > before whitespace,
        # whereas a valid SPARQL IRIREF cannot contain raw whitespace.
        if ($ch -eq '<' -and ($i + 1 -ge $Text.Length -or $Text[$i + 1] -ne '=')) {
            $j = $i + 1
            $found = $false
            while ($j -lt $Text.Length) {
                if ([char]::IsWhiteSpace($Text[$j])) { break }
                if ($Text[$j] -eq '>') { $found = $true; break }
                $j++
            }
            if ($found) {
                $tokens.Add((New-SparqlToken -Type 'Iri' -Text $Text.Substring($i, $j - $i + 1)))
                $i = $j + 1
                continue
            }
        }

        # Short and long RDF string literals. Escapes are preserved byte-for-byte.
        if ($ch -eq "'" -or $ch -eq '"') {
            $quote = $ch
            $isTriple = ($i + 2 -lt $Text.Length -and $Text[$i + 1] -eq $quote -and $Text[$i + 2] -eq $quote)
            $start = $i
            if ($isTriple) { $i += 3 } else { $i++ }
            while ($i -lt $Text.Length) {
                if ($Text[$i] -eq '\') {
                    $i += 2
                    continue
                }
                if ($isTriple) {
                    if ($i + 2 -lt $Text.Length -and $Text[$i] -eq $quote -and $Text[$i + 1] -eq $quote -and $Text[$i + 2] -eq $quote) {
                        $i += 3
                        break
                    }
                    $i++
                    continue
                }
                if ($Text[$i] -eq $quote) { $i++; break }
                $i++
            }
            $tokens.Add((New-SparqlToken -Type 'String' -Text $Text.Substring($start, $i - $start)))
            continue
        }

        # Variables. A lone ? can still be a property-path modifier and falls
        # through to the ordinary token branch.
        if (($ch -eq '?' -or $ch -eq '$') -and $i + 1 -lt $Text.Length -and [string]$Text[$i + 1] -match '[A-Za-z_]') {
            $start = $i
            $i += 2
            while ($i -lt $Text.Length -and [string]$Text[$i] -match '[A-Za-z0-9_]') { $i++ }
            $tokens.Add((New-SparqlToken -Type 'Variable' -Text $Text.Substring($start, $i - $start)))
            continue
        }

        $two = if ($i + 1 -lt $Text.Length) { $Text.Substring($i, 2) } else { '' }
        if ($two -in @('^^','!=','<=','>=','&&','||')) {
            $tokens.Add((New-SparqlToken -Type 'Operator' -Text $two))
            $i += 2
            continue
        }

        if ($ch -in @('{','}','(',')','[',']',';',',')) {
            $tokens.Add((New-SparqlToken -Type 'Punctuation' -Text ([string]$ch)))
            $i++
            continue
        }

        if ($ch -in @('=','!','<','>','|')) {
            $tokens.Add((New-SparqlToken -Type 'Operator' -Text ([string]$ch)))
            $i++
            continue
        }

        if ($ch -eq '.') {
            $tokens.Add((New-SparqlToken -Type 'Punctuation' -Text '.'))
            $i++
            continue
        }

        $start = $i
        while ($i -lt $Text.Length) {
            $c = $Text[$i]
            if ([char]::IsWhiteSpace($c) -or $c -in @('#','{','}','(',')','[',']',';',',','=','!','<','>','|',"'",'"')) { break }
            if ($c -eq '.') {
                $nextIsBoundary = ($i + 1 -ge $Text.Length -or [char]::IsWhiteSpace($Text[$i + 1]) -or $Text[$i + 1] -in @('}','{',')','(',';',','))
                if ($nextIsBoundary) { break }
            }
            $i++
        }
        if ($i -eq $start) {
            $tokens.Add((New-SparqlToken -Type 'Word' -Text ([string]$Text[$i])))
            $i++
        }
        else {
            $word = $Text.Substring($start, $i - $start)
            $upper = $word.ToUpperInvariant()
            if ($script:SparqlKeywords.ContainsKey($upper)) { $word = $upper }
            # The Turtle/SPARQL shorthand predicate `a` is intentionally kept
            # lowercase; changing it is not a presentation-only transformation.
            $tokens.Add((New-SparqlToken -Type 'Word' -Text $word))
        }
    }
    return @($tokens)
}

$script:SparqlLines = New-Object System.Collections.Generic.List[string]
$script:SparqlCurrent = ''
$script:SparqlIndent = 0
$script:SparqlContinuation = 0

function Get-SparqlLineIndent {
    return (' ' * ($script:SparqlIndent + $script:SparqlContinuation))
}

function Flush-SparqlLine {
    if (-not [string]::IsNullOrWhiteSpace($script:SparqlCurrent)) {
        $script:SparqlLines.Add($script:SparqlCurrent.TrimEnd())
    }
    $script:SparqlCurrent = ''
}

function Add-SparqlTokenText {
    param([string]$Text, [switch]$AttachLeft, [switch]$NoWrap)

    if (-not $script:SparqlCurrent) {
        $script:SparqlCurrent = (Get-SparqlLineIndent) + $Text
        return
    }

    $separator = ' '
    if ($AttachLeft -or $script:SparqlCurrent.EndsWith('(') -or $script:SparqlCurrent.EndsWith('[') -or $script:SparqlCurrent.EndsWith('^^')) {
        $separator = ''
    }
    if ($Text.StartsWith('@')) { $separator = '' }

    $candidate = $script:SparqlCurrent + $separator + $Text
    if (-not $NoWrap -and $candidate.Length -gt $script:MaxLineLength) {
        Flush-SparqlLine
        $wrapIndent = [Math]::Min($script:SparqlIndent + $script:SparqlContinuation + 2, 40)
        $script:SparqlCurrent = (' ' * $wrapIndent) + $Text
    }
    else {
        $script:SparqlCurrent = $candidate
    }
}

function Test-SparqlClauseStart {
    param([string]$Word)
    return $Word -in @(
        'PREFIX','BASE','SELECT','ASK','CONSTRUCT','DESCRIBE','FROM','WHERE','GROUP','HAVING','ORDER','LIMIT','OFFSET',
        'OPTIONAL','FILTER','BIND','VALUES','GRAPH','SERVICE','MINUS','USING','WITH','LOAD','CLEAR','DROP','CREATE','ADD','MOVE','COPY'
    )
}

function Format-SparqlTokens {
    param([object[]]$Tokens)

    for ($i = 0; $i -lt $Tokens.Count; $i++) {
        $token = $Tokens[$i]
        $text = [string]$token.Text
        $upper = $text.ToUpperInvariant()

        if ($token.Type -eq 'Comment') {
            Flush-SparqlLine
            $script:SparqlLines.Add((Get-SparqlLineIndent) + $text)
            continue
        }

        # A closing graph-pattern brace is held briefly so `} UNION {` can stay
        # on one structural line. Any other following term begins a new line.
        if ($script:SparqlCurrent.Trim() -eq '}' -and $upper -ne 'UNION' -and $text -ne '.' -and $text -ne '}') {
            Flush-SparqlLine
        }

        if ($upper -eq 'UNION') {
            if ($script:SparqlCurrent.Trim() -eq '}') {
                Add-SparqlTokenText -Text 'UNION'
            }
            else {
                Flush-SparqlLine
                $script:SparqlContinuation = 0
                Add-SparqlTokenText -Text 'UNION'
            }
            continue
        }

        if ($text -eq '{') {
            Add-SparqlTokenText -Text '{'
            Flush-SparqlLine
            $script:SparqlIndent += 2
            $script:SparqlContinuation = 0
            continue
        }

        if ($text -eq '}') {
            Flush-SparqlLine
            $script:SparqlIndent = [Math]::Max(0, $script:SparqlIndent - 2)
            $script:SparqlContinuation = 0
            $script:SparqlCurrent = (' ' * $script:SparqlIndent) + '}'
            continue
        }

        if ($text -eq ';') {
            Add-SparqlTokenText -Text ';'
            Flush-SparqlLine
            $script:SparqlContinuation = 2
            continue
        }

        if ($text -eq '.') {
            Add-SparqlTokenText -Text '.'
            Flush-SparqlLine
            $script:SparqlContinuation = 0
            continue
        }

        if ($text -eq ',') {
            Add-SparqlTokenText -Text ',' -AttachLeft
            continue
        }

        if ($text -eq ')'-or $text -eq ']') {
            Add-SparqlTokenText -Text $text -AttachLeft
            continue
        }

        if ($text -eq '(' -or $text -eq '[') {
            Add-SparqlTokenText -Text $text
            continue
        }

        if ($text -eq '^^') {
            Add-SparqlTokenText -Text $text -AttachLeft
            continue
        }

        if ($upper -eq 'INSERT' -or $upper -eq 'DELETE') {
            Flush-SparqlLine
            $script:SparqlContinuation = 0
            Add-SparqlTokenText -Text $upper
            continue
        }

        if (Test-SparqlClauseStart -Word $upper) {
            # DELETE WHERE is one SPARQL Update construct and should remain on a
            # single header line; ordinary query WHERE starts a fresh clause.
            if ($upper -eq 'WHERE' -and $script:SparqlCurrent.Trim() -eq 'DELETE') {
                Add-SparqlTokenText -Text 'WHERE'
                continue
            }

            Flush-SparqlLine
            $script:SparqlContinuation = 0
            Add-SparqlTokenText -Text $upper
            continue
        }

        Add-SparqlTokenText -Text $text
    }

    Flush-SparqlLine
    return @($script:SparqlLines)
}

$inputSparql = [Console]::In.ReadToEnd()
if ([string]::IsNullOrWhiteSpace($inputSparql)) { exit 0 }

$tokens = @(Get-SparqlTokens -Text $inputSparql)
$lines = @(Format-SparqlTokens -Tokens $tokens)
[Console]::Out.Write(($lines -join [Environment]::NewLine).TrimEnd())