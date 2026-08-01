Option Explicit

Dim fso, root, inputPath, outputDir, pdfPath, word, doc, pageCount
Set fso = CreateObject("Scripting.FileSystemObject")
root = fso.GetParentFolderName(fso.GetParentFolderName(WScript.ScriptFullName))
outputDir = fso.BuildPath(root, "build\report_qa")
inputPath = fso.BuildPath(outputDir, "report.docx")
pdfPath = fso.BuildPath(outputDir, "report_qa_temp.pdf")

WScript.Echo "WORD_START"
Set word = CreateObject("Word.Application")
word.Visible = False
word.DisplayAlerts = 0

On Error Resume Next
Set doc = word.Documents.Open(inputPath)
If Err.Number <> 0 Then
    WScript.Echo "WORD_OPEN_ERROR=" & Err.Number & ": " & Err.Description
    word.Quit
    WScript.Quit 2
End If
On Error GoTo 0

pageCount = doc.ComputeStatistics(2)
WScript.Echo "WORD_PAGES=" & pageCount
doc.ExportAsFixedFormat pdfPath, 17
WScript.Echo "WORD_EXPORTED"
doc.Close False
word.Quit

WScript.Echo pdfPath
