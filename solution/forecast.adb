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
--  calendar fact and never moves: an X day old release has X+1 days of history, opened lags 0
--  to X, so an N-day column is complete once N <= X and it holds floor(X/30) of them. An N-day
--  column counts a report opened by day N, lag 0 to N; the day-365 total counts lag 0 to 365,
--  and a release 365 days old or more has that total in the file, so it is the forecast itself.
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
   type Count_Row  is array (0 .. Columns - 1) of Long_Long_Integer;
   type Source_Counts is array (Source) of Count_Row;

   type Release is record
      Version   : Unbounded_String;
      Day       : Integer;            --  release date as a day number
      Reporter  : Boolean;            --  ships the crash reporter
      Complete  : Natural;            --  columns available to forecast from, floor(Age/30)
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

   --  Complete thirty-day columns available to divide a forecast by: floor(Age/30), the same
   --  rule at every age (a release's history runs to lag Age inclusive, the export date being
   --  in the file), capped at Columns - 1 because the curve only publishes points up to 360
   --  days. A finished release never divides at all (Ultimate below reads its day-365 count),
   --  so the cap only matters between 360 and 364 days.
   function Complete_Columns (Age : Integer) return Natural is
      N : Integer := Age / 30;
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
      return 30 * (P + 1);
   end Column_Limit;

   --  Index just past the colon of the top-level member Name of the JSON object in S, or 0.
   --  The text is walked as JSON rather than searched: a string value that happens to read
   --  "horizon_days", or a member nested inside another value, is passed over.
   function Member (S : String; Name : String) return Natural is
      Depth    : Integer := 0;
      I        : Natural := S'First;
      Key      : Natural := 0;       --  the last key read at depth 1, S (Key .. Key_End)
      Key_End  : Natural := 0;
      Want_Key : Boolean := False;   --  at depth 1, the next string is a key
   begin
      while I <= S'Last loop
         case S (I) is
            when '"' =>
               declare
                  J : Natural := I + 1;
               begin
                  while J <= S'Last and then S (J) /= '"' loop
                     if S (J) = '\' then
                        J := J + 1;
                     end if;
                     J := J + 1;
                  end loop;
                  if Depth = 1 and then Want_Key then
                     Key := I + 1;
                     Key_End := J - 1;
                     Want_Key := False;
                  end if;
                  I := J;
               end;
            when '{' | '[' =>
               Depth := Depth + 1;
               Want_Key := Depth = 1;
            when '}' | ']' =>
               Depth := Depth - 1;
            when ',' =>
               Want_Key := Depth = 1;
            when ':' =>
               if Depth = 1 and then Key > 0 and then S (Key .. Key_End) = Name then
                  return I + 1;
               end if;
            when others =>
               null;
         end case;
         I := I + 1;
      end loop;
      return 0;
   end Member;

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
         --  The horizon the whole report is shaped around is checked before anything else
         --  is read out of the file: a policy that asks for another day gets the exit
         --  status the task documents, whatever else it holds.
         P := Member (S, "horizon_days");
         if P = 0 then
            raise Program_Error with "policy.json has no horizon_days";
         end if;
         --  JSON whitespace is any of four bytes, not only a space: a tab between the colon
         --  and the value is as legal as a space and must not read as a missing number.
         while P <= S'Last
           and then (S (P) = ' ' or else S (P) = ASCII.HT
                     or else S (P) = ASCII.LF or else S (P) = ASCII.CR)
         loop
            P := P + 1;
         end loop;
         --  The whole number token, not a digit prefix: 365.0, 365e0 and 3.65e2 all start
         --  with 365 and none is the integer 365. Only the bare token "365", followed by the
         --  comma or brace that ends a JSON value, is the horizon; anything else is refused
         --  without being converted, so a twenty-digit numeral cannot overflow anything.
         Q := P;
         while Q <= S'Last
           and then (S (Q) in '0' .. '9' or else S (Q) = '-' or else S (Q) = '+'
                     or else S (Q) = '.' or else S (Q) = 'e' or else S (Q) = 'E')
         loop
            Q := Q + 1;
         end loop;
         if S (P .. Q - 1) /= "365" then
            raise Wrong_Horizon;
         end if;
         while Q <= S'Last
           and then (S (Q) = ' ' or else S (Q) = ASCII.HT
                     or else S (Q) = ASCII.LF or else S (Q) = ASCII.CR)
         loop
            Q := Q + 1;
         end loop;
         if Q > S'Last or else (S (Q) /= ',' and then S (Q) /= '}') then
            raise Wrong_Horizon;
         end if;

         P := Member (S, "export_date");
         if P = 0 then
            raise Program_Error with "policy.json has no export_date";
         end if;
         P := Index (S, """", P);
         Q := Index (S, """", P + 1);
         Export_Day := Parse_Date (S (P + 1 .. Q - 1));

         P := Member (S, "forecast_releases");
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

   --  A release's day-365 figure for one source, the README's method rule for rule: a finished
   --  release has its whole record, so its day-365 count is the figure; otherwise its reports by
   --  its last complete age over the curve's share at that age. The two guards never fire on an
   --  export that keeps the README's facts (every forecast release is at least 60 days old and
   --  every share it divides by is positive); they keep a division by zero out of one that does not.
   function Ultimate (I : Positive; Src : Source; Share : Column_Row) return Long_Float is
      K : constant Integer := Rel (I).Complete - 1;   --  last complete column
   begin
      if Rel (I).Finished then
         return Long_Float (Rel (I).Counts (Src) (Columns - 1));
      end if;
      if K < 0 then
         return Long_Float (Rel (I).Counts (Src) (0));
      end if;
      if Share (K) <= 0.0 then
         return Long_Float (Rel (I).Counts (Src) (K));
      end if;
      return Long_Float (Rel (I).Counts (Src) (K)) / Share (K);
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
         N     : Long_Long_Integer;
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
         N := Long_Long_Integer (Long_Float'Rounding (Total));
         if J > 1 then
            Put (Result, ",");
         end if;
         Put (Result, """" & To_String (Forecast_Versions (J)) & """:" & Trim (Long_Long_Integer'Image (N), Ada.Strings.Left));
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
