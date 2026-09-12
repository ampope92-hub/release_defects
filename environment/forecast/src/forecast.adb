--  Report forecast for the young releases.
--  Usage: forecast <data-dir> <output-json>. Writes the count each release in the policy's
--  forecast list will have reached by day 365.

with Ada.Text_IO;       use Ada.Text_IO;
with Ada.Command_Line;  use Ada.Command_Line;

procedure Forecast is
begin
   if Argument_Count /= 2 then
      Put_Line (Standard_Error, "usage: forecast <data-dir> <output-json>");
      Set_Exit_Status (2);
      return;
   end if;
   --  TODO: read the export in Argument (1), work the counts out, write Argument (2)
   Put_Line (Standard_Error, "not implemented");
   Set_Exit_Status (1);
end Forecast;
