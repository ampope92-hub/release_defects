--  Forecast of the reports each young release will have collected by day 365.
--
--  The memo's table is reports received to date over installs, and a release that shipped
--  ten weeks ago has simply not had time to collect its tickets: they trail the release by
--  weeks and months. What the older releases give is the pattern of that trailing, column by
--  column of 30 days, and a young release's count grows by the same pattern. Two things
--  arrive on two clocks. Tickets take months and every release has them. Crash reports come
--  from the crash reporter, which only the later releases ship, and they land within days.
--  Grossing a reporter-era release up by the pattern of the ticket-only releases would treat
--  crash reports that are already all in as if they were still trickling, so each source gets
--  its own pattern, tickets from every release and crash reports from the releases that have
--  the reporter, and the two ultimates are added.
--
--  A report also carries a status and an opened_date. A duplicate or invalid report is not a
--  defect and is skipped outright, everywhere: not in a column count, not in a curve, not in
--  the count a young release divides by its curve. opened_date, not reported_date, is the day
--  a column count is built from: reported_date is only the day the tracker logged the report,
--  which lags opened_date by a triage queue for tickets, and the two dates match for crash
--  reports, which have no queue.
--
--  A release's age in days, and so which columns the export holds complete for it, is still a
--  calendar fact and never moves: an X day old release has X+1 days of history, so it holds
--  floor((X+1)/30) complete 30-day columns. An N-day column counts a report if its opened lag
--  is 0 to N-1; the day-365 total counts opened lag 0 to 365.
--
--  Usage: forecast <data-dir> <output-json>

with Ada.Text_IO;            use Ada.Text_IO;
with Ada.Command_Line;       use Ada.Command_Line;
with Ada.Strings.Fixed;      use Ada.Strings.Fixed;
with Ada.Strings.Unbounded;  use Ada.Strings.Unbounded;

procedure Forecast is

   Columns : constant := 13;   --  0 .. 12: twelve 30-day columns, then "by day 365"
   Horizon : constant := 365;  --  policy.horizon_days; the output shape is built around it

   --  Raised when policy.json asks for a horizon this report is not shaped for. The main body
   --  turns it into the exit status the task documents, rather than letting it reach the runtime
   --  as an unhandled exception with a traceback and an exit status nobody asked for.
   Wrong_Horizon : exception;

   type Source is (Ticket, Crash);
   type Column_Row is array (0 .. Columns - 1) of Long_Float;
   type Count_Row  is array (0 .. Columns - 1) of Natural;
   type Source_Counts is array (Source) of Count_Row;

   type Release is record
      Version   : Unbounded_String;
      Day       : Integer;            --  release date as a day number
      Reporter  : Boolean;            --  ships the crash reporter
      Complete  : Natural;            --  columns available to forecast from, floor((Age+1)/30)
                                       --  capped at Columns - 1; independent of whether the
                                       --  release has finished collecting
      Finished  : Boolean;            --  Age >= Horizon: eligible for the arrival-curve cohort
      Counts    : Source_Counts;
   end record;

   --  Both lists grow with the export. A product's history is as long as it is, and the format
   --  puts no ceiling on it, so neither does this.
   type Release_Array is array (Positive range <>) of Release;
   type Release_List  is access Release_Array;
   type Version_Array is array (Positive range <>) of Unbounded_String;
   type Version_List  is access Version_Array;

   Rel   : Release_List := new Release_Array (1 .. 256);
   N_Rel : Natural := 0;

   Forecast_Versions : Version_List := new Version_Array (1 .. 64);
   N_Forecast        : Natural := 0;
   Export_Day        : Integer := 0;

   procedure Room_For_Release is
      Bigger : Release_List;
   begin
      if N_Rel < Rel'Last then
         return;
      end if;
      Bigger := new Release_Array (1 .. 2 * Rel'Last);
      Bigger (1 .. N_Rel) := Rel (1 .. N_Rel);
      Rel := Bigger;
   end Room_For_Release;

   procedure Room_For_Version is
      Bigger : Version_List;
   begin
      if N_Forecast < Forecast_Versions'Last then
         return;
      end if;
      Bigger := new Version_Array (1 .. 2 * Forecast_Versions'Last);
      Bigger (1 .. N_Forecast) := Forecast_Versions (1 .. N_Forecast);
      Forecast_Versions := Bigger;
   end Room_For_Version;

   --  Days since a fixed epoch for a civil date; only differences are used.
   function Day_Number (Y, M, D : Integer) return Integer is
      YY : Integer := Y;
      MM : Integer := M;
   begin
      if MM <= 2 then
         YY := YY - 1;
         MM := MM + 12;
      end if;
      return 365 * YY + YY / 4 - YY / 100 + YY / 400 + (153 * (MM - 3) + 2) / 5 + D - 1;
   end Day_Number;

   function Parse_Date (S : String) return Integer is
      --  YYYY-MM-DD
      T : constant String := Trim (S, Ada.Strings.Both);
   begin
      return Day_Number (Integer'Value (T (T'First .. T'First + 3)),
                         Integer'Value (T (T'First + 5 .. T'First + 6)),
                         Integer'Value (T (T'First + 8 .. T'First + 9)));
   end Parse_Date;

   --  Field K (1-based) of a comma separated line, trailing CR stripped.
   function Field (Line : String; K : Positive) return String is
      Start : Integer := Line'First;
      Count : Positive := 1;
   begin
      for I in Line'Range loop
         if Line (I) = ',' then
            if Count = K then
               return Line (Start .. I - 1);
            end if;
            Count := Count + 1;
            Start := I + 1;
         end if;
      end loop;
      if Count = K then
         if Line'Length > 0 and then Line (Line'Last) = ASCII.CR then
            return Line (Start .. Line'Last - 1);
         end if;
         return Line (Start .. Line'Last);
      end if;
      return "";
   end Field;

   function Find_Release (V : String) return Natural is
   begin
      for I in 1 .. N_Rel loop
         if To_String (Rel (I).Version) = V then
            return I;
         end if;
      end loop;
      return 0;
   end Find_Release;

   --  Complete thirty-day columns available to divide a forecast by: floor((Age+1)/30), the
   --  same rule at every age, capped at Columns - 1 because the curve only publishes points up
   --  to 360 days (age 359 already reaches that cap). This never special-cases Age >= Horizon:
   --  a release exactly 365 days old still gets its last complete column at day 360, not the
   --  full day-365 total, because the contract's column formula and the curve's cohort cutoff
   --  are two different rules and must not be folded into one field.
   function Complete_Columns (Age : Integer) return Natural is
      N : Integer := (Age + 1) / 30;
   begin
      if N > Columns - 1 then
         N := Columns - 1;
      end if;
      if N < 0 then
         N := 0;
      end if;
      return N;
   end Complete_Columns;

   function Column_Limit (P : Natural) return Integer is
   begin
      if P = Columns - 1 then
         return Horizon;
      end if;
      return 30 * (P + 1) - 1;
   end Column_Limit;

   procedure Read_Policy (Path : String) is
      F    : File_Type;
      Text : Unbounded_String;
   begin
      Open (F, In_File, Path);
      while not End_Of_File (F) loop
         Append (Text, Get_Line (F));
         Append (Text, ' ');
      end loop;
      Close (F);
      declare
         S : constant String := To_String (Text);
         P : Natural;
         Q : Natural;
      begin
         P := Index (S, """export_date""");
         if P = 0 then
            raise Program_Error with "policy.json has no export_date";
         end if;
         P := Index (S, ":", P);
         P := Index (S, """", P);
         Q := Index (S, """", P + 1);
         Export_Day := Parse_Date (S (P + 1 .. Q - 1));

         --  The horizon the whole report is shaped around. Read it and refuse anything
         --  else, rather than quietly returning a day-365 answer to a policy that asked
         --  for another day.
         P := Index (S, """horizon_days""");
         if P = 0 then
            raise Program_Error with "policy.json has no horizon_days";
         end if;
         P := Index (S, ":", P) + 1;
         while P <= S'Last and then S (P) = ' ' loop
            P := P + 1;
         end loop;
         Q := P;
         while Q <= S'Last and then S (Q) in '0' .. '9' loop
            Q := Q + 1;
         end loop;
         if Q = P or else Integer'Value (S (P .. Q - 1)) /= Horizon then
            raise Wrong_Horizon;
         end if;

         P := Index (S, """forecast_releases""");
         if P = 0 then
            raise Program_Error with "policy.json has no forecast_releases";
         end if;
         P := Index (S, "[", P);
         Q := Index (S, "]", P);
         declare
            I : Natural := P;
            A, B : Natural;
         begin
            loop
               A := Index (S (I + 1 .. Q), """");
               exit when A = 0;
               B := Index (S (A + 1 .. Q), """");
               exit when B = 0;
               Room_For_Version;
               N_Forecast := N_Forecast + 1;
               Forecast_Versions (N_Forecast) := To_Unbounded_String (S (A + 1 .. B - 1));
               I := B;
            end loop;
         end;
      end;
   end Read_Policy;

   procedure Read_Releases (Path : String) is
      F     : File_Type;
      First : Boolean := True;
   begin
      Open (F, In_File, Path);
      while not End_Of_File (F) loop
         declare
            Line : constant String := Get_Line (F);
         begin
            if First then
               First := False;
            elsif Line'Length > 0 then
               Room_For_Release;
               N_Rel := N_Rel + 1;
               Rel (N_Rel).Version  := To_Unbounded_String (Field (Line, 1));
               Rel (N_Rel).Day      := Parse_Date (Field (Line, 2));
               Rel (N_Rel).Reporter := Field (Line, 4) = "yes";
               Rel (N_Rel).Complete := Complete_Columns (Export_Day - Rel (N_Rel).Day);
               Rel (N_Rel).Finished := Export_Day - Rel (N_Rel).Day >= Horizon;
               for Src in Source loop
                  Rel (N_Rel).Counts (Src) := (others => 0);
               end loop;
            end if;
         end;
      end loop;
      Close (F);
   end Read_Releases;

   procedure Read_Reports (Path : String) is
      F     : File_Type;
      First : Boolean := True;
   begin
      Open (F, In_File, Path);
      while not End_Of_File (F) loop
         declare
            Line : constant String := Get_Line (F);
         begin
            if First then
               First := False;
            elsif Line'Length > 0 then
               declare
                  I   : constant Natural := Find_Release (Field (Line, 2));
                  Src : Source;
                  Lag : Integer;
               begin
                  --  A duplicate or invalid report is not a defect. It is skipped here, so it
                  --  never reaches a column count, a curve, or the count a young release
                  --  divides by its curve.
                  if I > 0 and then Field (Line, 5) = "open" then
                     if Field (Line, 4) = "crash" then
                        Src := Crash;
                     else
                        Src := Ticket;
                     end if;
                     --  opened_date (field 6), not reported_date (field 3): reported_date is
                     --  only the day the tracker logged the report, which trails opened_date
                     --  by a triage queue for tickets and matches it for crash reports.
                     Lag := Parse_Date (Field (Line, 6)) - Rel (I).Day;
                     for P in 0 .. Columns - 1 loop
                        if Lag <= Column_Limit (P) then
                           Rel (I).Counts (Src) (P) := Rel (I).Counts (Src) (P) + 1;
                        end if;
                     end loop;
                  end if;
               end;
            end if;
         end;
      end loop;
      Close (F);
   end Read_Reports;


   --  The share of a release's eventual day-365 total that has arrived by each column
   --  boundary, pooled over the releases that have finished collecting.
   procedure Arrival (Src : Source; Reporter_Only : Boolean; Share : out Column_Row) is
      Ult, Num : Long_Float;

      function In_Cohort (I : Positive) return Boolean is
      begin
         return Rel (I).Finished
           and then (not Reporter_Only or else Rel (I).Reporter);
      end In_Cohort;
   begin
      Share := (others => 1.0);
      Ult := 0.0;
      for I in 1 .. N_Rel loop
         if In_Cohort (I) then
            Ult := Ult + Long_Float (Rel (I).Counts (Src) (Columns - 1));
         end if;
      end loop;
      if Ult <= 0.0 then
         return;
      end if;
      for P in 0 .. Columns - 2 loop
         Num := 0.0;
         for I in 1 .. N_Rel loop
            if In_Cohort (I) then
               Num := Num + Long_Float (Rel (I).Counts (Src) (P));
            end if;
         end loop;
         Share (P) := Num / Ult;
      end loop;
   end Arrival;

   --  A share written to four decimal places, so the report carries no exponent form.
   function Fmt (X : Long_Float) return String is
      N : constant Integer := Integer (Long_Float'Rounding (X * 10000.0));
      W : constant Integer := N / 10000;
      F : constant Integer := abs (N - W * 10000);
      FS : String (1 .. 4) := (others => '0');
      T  : constant String := Trim (Integer'Image (F), Ada.Strings.Left);
   begin
      FS (5 - T'Length .. 4) := T;
      return Trim (Integer'Image (W), Ada.Strings.Left) & "." & FS;
   end Fmt;

   --  A share rounded to the four places the report prints, so the figure a forecast divides by
   --  is exactly the figure written under arrival_share, not a longer version of it.
   function Rounded (X : Long_Float) return Long_Float is
   begin
      return Long_Float (Integer (Long_Float'Rounding (X * 10000.0))) / 10000.0;
   end Rounded;

   --  A release's day-365 figure for one source: its reports over its last whole thirty-day
   --  column, divided by the curve's share at that column.
   function Ultimate (I : Positive; Src : Source; Share : Column_Row) return Long_Float is
      K : constant Integer := Rel (I).Complete - 1;   --  last complete column
      S : Long_Float;
   begin
      if K < 0 then
         return 0.0;
      end if;
      S := Rounded (Share (K));
      if S <= 0.0 then
         return 0.0;
      end if;
      return Long_Float (Rel (I).Counts (Src) (K)) / S;
   end Ultimate;

   Ticket_Share, Crash_Share     : Column_Row;
   Result : File_Type;

begin
   if Argument_Count /= 2 then
      Put_Line (Standard_Error, "usage: forecast <data-dir> <output-json>");
      Set_Exit_Status (2);
      return;
   end if;

   begin
      Read_Policy (Argument (1) & "/policy.json");
   exception
      when Wrong_Horizon =>
         Put_Line (Standard_Error,
                   "this report is shaped around a 365 day horizon; policy.json asks for another");
         Set_Exit_Status (3);
         return;
   end;

   Read_Releases (Argument (1) & "/releases.csv");
   Read_Reports (Argument (1) & "/reports.csv");

   Arrival (Ticket, False, Ticket_Share);
   Arrival (Crash, True, Crash_Share);

   Create (Result, Ada.Text_IO.Out_File, Argument (2));
   Put (Result, "{""reports_by_day_365"":{");
   for J in 1 .. N_Forecast loop
      declare
         I     : constant Natural := Find_Release (To_String (Forecast_Versions (J)));
         Total : Long_Float := 0.0;
         N     : Natural;
      begin
         if I = 0 then
            raise Program_Error with "forecast release missing from releases.csv: " & To_String (Forecast_Versions (J));
         end if;
         --  Both sources are added for every forecast release. Only the crash CURVE cohort is
         --  reporter-restricted (Arrival above), not a release's own crash term: a release that
         --  carries crash reports still gets them grossed up, whatever its crash_reporter column
         --  says. A release with no crash reports contributes a zero here, so this is a no-op for
         --  the ordinary ticket-only release.
         Total := Ultimate (I, Ticket, Ticket_Share) + Ultimate (I, Crash, Crash_Share);
         N := Natural (Long_Float'Rounding (Total));
         if J > 1 then
            Put (Result, ",");
         end if;
         Put (Result, """" & To_String (Forecast_Versions (J)) & """:" & Trim (Natural'Image (N), Ada.Strings.Left));
         Put_Line (Standard_Error, To_String (Forecast_Versions (J)) & ": " & Trim (Natural'Image (N), Ada.Strings.Left));
      end;
   end loop;
   Put (Result, "},""arrival_share"":{""ticket"":{");
   for P in 0 .. Columns - 2 loop
      if P > 0 then
         Put (Result, ",");
      end if;
      Put (Result, """" & Trim (Integer'Image ((P + 1) * 30), Ada.Strings.Left)
                  & """:" & Fmt (Ticket_Share (P)));
   end loop;
   Put (Result, "},""crash"":{");
   for P in 0 .. Columns - 2 loop
      if P > 0 then
         Put (Result, ",");
      end if;
      Put (Result, """" & Trim (Integer'Image ((P + 1) * 30), Ada.Strings.Left)
                  & """:" & Fmt (Crash_Share (P)));
   end loop;
   Put_Line (Result, "}}}");
   Close (Result);
end Forecast;
