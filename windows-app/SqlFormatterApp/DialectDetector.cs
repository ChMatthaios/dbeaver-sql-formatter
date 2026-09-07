using System.Text.RegularExpressions;

namespace SqlFormatterApp;

public static partial class DialectDetector
{
    public static string Detect(string text)
    {
        if (string.IsNullOrWhiteSpace(text))
        {
            return "Auto";
        }

        var normalized = Regex.Replace(text, @"\s+", " ").Trim();

        if (LooksLikeSparql(text, normalized))
        {
            return "SPARQL";
        }

        if (Regex.IsMatch(normalized, @"(?i)(^|\s)(TOP\s*\(?\d|CROSS\s+APPLY|OUTER\s+APPLY|OUTPUT\b|OPTION\s*\(|CREATE\s+OR\s+ALTER\b|BEGIN\s+TRY\b|END\s+CATCH\b|@@?\w+|##?\w+)") ||
            Regex.IsMatch(text, @"(?im)^\s*GO(?:\s+\d+)?\s*$"))
        {
            return "T-SQL";
        }

        if (Regex.IsMatch(normalized, @"(?i)(:=|%TYPE\b|%ROWTYPE\b|\bCONNECT\s+BY\b|\bSTART\s+WITH\b|\bVARCHAR2\b|\bDBMS_\w+\s*\.|\bFROM\s+DUAL\b|\bPRAGMA\b|\bSYS_REFCURSOR\b)") ||
            Regex.IsMatch(text, @"(?im)^\s*/\s*$"))
        {
            return "Oracle / PL-SQL";
        }

        if (Regex.IsMatch(normalized, @"(?i)(::|\bON\s+CONFLICT\b|\bILIKE\b|\bDISTINCT\s+ON\s*\(|\bWITH\s+RECURSIVE\b|\bRETURNING\b|->>|->|#>>|#>)") ||
            Regex.IsMatch(text, @"\$\$|\$[A-Za-z_]\w*\$"))
        {
            return "PostgreSQL";
        }

        return "DB2 / ANSI SQL";
    }

    private static bool LooksLikeSparql(string text, string normalized)
    {
        if (Regex.IsMatch(text, @"(?im)^\s*(PREFIX|BASE)\s+"))
        {
            return true;
        }

        if (Regex.IsMatch(normalized, @"(?i)\b(ASK|CONSTRUCT|DESCRIBE)\b.*\{") ||
            Regex.IsMatch(normalized, @"(?i)\b(INSERT|DELETE)\s+DATA\s*\{") ||
            Regex.IsMatch(normalized, @"(?i)\bDELETE\s+WHERE\s*\{"))
        {
            return true;
        }

        return Regex.IsMatch(normalized, @"(?i)\bSELECT\b.*\?[A-Za-z_]\w*.*\bWHERE\s*\{");
    }
}
