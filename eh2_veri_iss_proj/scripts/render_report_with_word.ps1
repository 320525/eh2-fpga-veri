$ErrorActionPreference = 'Stop'

$inputPath = (Resolve-Path 'reports\VeeR-EH2双DDR4系统设计与验证报告.docx').Path
$outputDir = (Resolve-Path 'build\report_qa').Path
$pdfPath = Join-Path $outputDir 'report_qa_temp.pdf'

Write-Output 'WORD_START'
$word = New-Object -ComObject Word.Application
$word.Visible = $false
$word.DisplayAlerts = 0
$word.AutomationSecurity = 3

try {
    Write-Output 'WORD_OPEN'
    $document = $word.Documents.Open($inputPath)
    $pageCount = $document.ComputeStatistics(2)
    Write-Output "WORD_PAGES=$pageCount"
    $document.ExportAsFixedFormat($pdfPath, 17)
    Write-Output 'WORD_EXPORTED'
    $document.Close($false)
}
finally {
    $word.Quit()
}

Get-Item $pdfPath | Select-Object FullName, Length, LastWriteTime
