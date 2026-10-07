#Requires AutoHotkey v2.0.19+
#SingleInstance Off
fixture := Gui(, "Keyboard conversion accessibility test")
fixture.AddEdit("w420 r4", "")
fixture.OnEvent("Close", (*) => ExitApp())
fixture.Show("NA")

