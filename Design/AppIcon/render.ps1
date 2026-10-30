# Renders the three SVGs to 1024x1024 PNGs with headless Edge.
$edge = "C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe"
$d = $PSScriptRoot
foreach ($n in "AppIcon","AppIcon-Dark","AppIcon-Tinted") {
  & $edge --headless --disable-gpu --hide-scrollbars "--screenshot=$d\$n.png" --window-size=1024,1024 "file:///$($d -replace '\','/')/$n.svg" 2>$null | Out-Null
}
