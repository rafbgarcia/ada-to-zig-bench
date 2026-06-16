with Ada.Calendar;
with Ada.Characters.Handling;
with Ada.Environment_Variables;
with Ada.Exceptions;
with Ada.IO_Exceptions;
with Ada.Strings;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with Ada.Text_IO;
with GNAT.Sockets;
with GNATCOLL.JSON;

procedure Server is
   use Ada.Strings;
   use Ada.Strings.Fixed;
   use Ada.Strings.Unbounded;
   use GNAT.Sockets;
   use GNATCOLL.JSON;
   use type Ada.Calendar.Time;

   Max_Safe_Integer : constant Long_Long_Integer := 9_007_199_254_740_991;
   Started_At       : constant Ada.Calendar.Time := Ada.Calendar.Clock;

   type U32 is mod 2 ** 32;
   type Port_Array is array (Positive range <>) of Port_Type;

   protected Metrics is
      procedure Start_Request;
      procedure Finish_Request;
      procedure Record_Response (Status : Natural);
      procedure Record_Error;
      function Active_Requests return Long_Long_Integer;
      function Requests_Started return Long_Long_Integer;
      function Responses_Completed return Long_Long_Integer;
      function Responses_2xx return Long_Long_Integer;
      function Responses_4xx return Long_Long_Integer;
      function Responses_5xx return Long_Long_Integer;
      function Request_Errors return Long_Long_Integer;
   private
      Active      : Long_Long_Integer := 0;
      Started     : Long_Long_Integer := 0;
      Completed   : Long_Long_Integer := 0;
      Bucket_2xx  : Long_Long_Integer := 0;
      Bucket_4xx  : Long_Long_Integer := 0;
      Bucket_5xx  : Long_Long_Integer := 0;
      Errors      : Long_Long_Integer := 0;
   end Metrics;

   protected body Metrics is
      procedure Start_Request is
      begin
         Active := Active + 1;
         Started := Started + 1;
      end Start_Request;

      procedure Finish_Request is
      begin
         Active := Active - 1;
      end Finish_Request;

      procedure Record_Response (Status : Natural) is
      begin
         Completed := Completed + 1;
         if Status >= 200 and then Status < 300 then
            Bucket_2xx := Bucket_2xx + 1;
         elsif Status >= 400 and then Status < 500 then
            Bucket_4xx := Bucket_4xx + 1;
         elsif Status >= 500 then
            Bucket_5xx := Bucket_5xx + 1;
         end if;
      end Record_Response;

      procedure Record_Error is
      begin
         Errors := Errors + 1;
      end Record_Error;

      function Active_Requests return Long_Long_Integer is (Active);
      function Requests_Started return Long_Long_Integer is (Started);
      function Responses_Completed return Long_Long_Integer is (Completed);
      function Responses_2xx return Long_Long_Integer is (Bucket_2xx);
      function Responses_4xx return Long_Long_Integer is (Bucket_4xx);
      function Responses_5xx return Long_Long_Integer is (Bucket_5xx);
      function Request_Errors return Long_Long_Integer is (Errors);
   end Metrics;

   function Env (Name : String; Default : String := "") return String is
   begin
      if Ada.Environment_Variables.Exists (Name) then
         declare
            Value : constant String := Ada.Environment_Variables.Value (Name);
         begin
            if Value'Length > 0 then
               return Value;
            end if;
         end;
      end if;
      return Default;
   end Env;

   function Count_Port_Items (Value : String) return Natural is
      Count : Natural := 0;
      Start : Positive := Value'First;
      Comma : Natural;
   begin
      while Start <= Value'Last loop
         Comma := Index (Value, ",", Start);
         declare
            Stop : constant Natural := (if Comma = 0 then Value'Last else Comma - 1);
            Item : constant String := Trim (Value (Start .. Stop), Both);
         begin
            if Item'Length > 0 then
               Count := Count + 1;
            end if;
         end;
         exit when Comma = 0;
         Start := Comma + 1;
      end loop;
      return Count;
   end Count_Port_Items;

   function Parse_Ports (Value : String) return Port_Array is
      Count : constant Natural := Count_Port_Items (Value);
      Result : Port_Array (1 .. Count);
      Index_Out : Positive := 1;
      Start : Positive := Value'First;
      Comma : Natural;
   begin
      if Count = 0 then
         raise Constraint_Error with "PORTS must contain at least one TCP port";
      end if;

      while Start <= Value'Last loop
         Comma := Index (Value, ",", Start);
         declare
            Stop : constant Natural := (if Comma = 0 then Value'Last else Comma - 1);
            Item : constant String := Trim (Value (Start .. Stop), Both);
            Parsed : Integer;
         begin
            if Item'Length > 0 then
               Parsed := Integer'Value (Item);
               if Parsed <= 0 or else Parsed >= 65_536 then
                  raise Constraint_Error with "invalid port";
               end if;
               Result (Index_Out) := Port_Type (Parsed);
               Index_Out := Index_Out + 1;
            end if;
         end;
         exit when Comma = 0;
         Start := Comma + 1;
      end loop;
      return Result;
   end Parse_Ports;

   function Image (Value : Long_Long_Integer) return String is
   begin
      return Trim (Long_Long_Integer'Image (Value), Both);
   end Image;

   function Image_U32 (Value : U32) return String is
   begin
      return Trim (U32'Image (Value), Both);
   end Image_U32;

   function Now_ISO return String is
      Now : constant Ada.Calendar.Time := Ada.Calendar.Clock;
      Year : Ada.Calendar.Year_Number;
      Month : Ada.Calendar.Month_Number;
      Day : Ada.Calendar.Day_Number;
      Seconds : Ada.Calendar.Day_Duration;
      Hour : Natural;
      Minute : Natural;
      Second : Natural;

      function Two (N : Natural) return String is
         S : constant String := Trim (Natural'Image (N), Both);
      begin
         if S'Length = 1 then
            return "0" & S;
         else
            return S;
         end if;
      end Two;
   begin
      Ada.Calendar.Split (Now, Year, Month, Day, Seconds);
      Hour := Natural (Seconds) / 3600;
      Minute := (Natural (Seconds) mod 3600) / 60;
      Second := Natural (Seconds) mod 60;
      return Image (Long_Long_Integer (Year)) & "-" & Two (Natural (Month)) & "-" & Two (Natural (Day)) &
        "T" & Two (Hour) & ":" & Two (Minute) & ":" & Two (Second) & "Z";
   end Now_ISO;

   function Elapsed_Seconds return Long_Long_Integer is
      Diff : constant Duration := Ada.Calendar.Clock - Started_At;
   begin
      return Long_Long_Integer (Diff);
   end Elapsed_Seconds;

   function Checksum (Payload : String) return U32 is
      Value : U32 := 2_166_136_261;
   begin
      for Ch of Payload loop
         Value := Value xor U32 (Character'Pos (Ch));
         Value := Value * 16_777_619;
      end loop;
      return Value;
   end Checksum;

   function Response (Status : Natural; Response_Body : String) return String is
      Reason : constant String := (case Status is
         when 200 => "OK",
         when 400 => "Bad Request",
         when 404 => "Not Found",
         when others => "Internal Server Error");
   begin
      return "HTTP/1.1 " & Trim (Natural'Image (Status), Both) & " " & Reason & ASCII.CR & ASCII.LF &
        "Connection: keep-alive" & ASCII.CR & ASCII.LF &
        "Content-Type: application/json" & ASCII.CR & ASCII.LF &
        "Content-Length: " & Trim (Natural'Image (Response_Body'Length), Both) & ASCII.CR & ASCII.LF &
        ASCII.CR & ASCII.LF & Response_Body;
   end Response;

   function Runtime_JSON return String is
   begin
      return "{""ts"":""" & Now_ISO & """,""elapsed_seconds"":" & Image (Elapsed_Seconds) &
        ",""runtime"":""ada-gnat""}";
   end Runtime_JSON;

   function Activity_JSON return String is
   begin
      return "{""ts"":""" & Now_ISO & """,""elapsed_seconds"":" & Image (Elapsed_Seconds) &
        ",""active_connections"":null,""accepted_connections_total"":null,""closed_connections_total"":null" &
        ",""active_requests"":" & Image (Metrics.Active_Requests) &
        ",""requests_started_total"":" & Image (Metrics.Requests_Started) &
        ",""responses_completed_total"":" & Image (Metrics.Responses_Completed) &
        ",""responses_2xx_total"":" & Image (Metrics.Responses_2xx) &
        ",""responses_4xx_total"":" & Image (Metrics.Responses_4xx) &
        ",""responses_5xx_total"":" & Image (Metrics.Responses_5xx) &
        ",""request_errors_total"":" & Image (Metrics.Request_Errors) & "}";
   end Activity_JSON;

   function Read_Line (Channel : Stream_Access) return String is
      Buffer : Unbounded_String;
      Ch : Character;
   begin
      loop
         Character'Read (Channel, Ch);
         if Ch = ASCII.LF then
            return To_String (Buffer);
         elsif Ch /= ASCII.CR then
            Append (Buffer, Ch);
         end if;
      end loop;
   end Read_Line;

   function Read_Exact (Channel : Stream_Access; Length : Natural) return String is
      Result : String (1 .. Length);
   begin
      for I in Result'Range loop
         Character'Read (Channel, Result (I));
      end loop;
      return Result;
   end Read_Exact;

   procedure Write_String (Channel : Stream_Access; Value : String) is
   begin
      for Ch of Value loop
         Character'Write (Channel, Ch);
      end loop;
   end Write_String;

   function Path_Only (Target : String) return String is
      Q : constant Natural := Index (Target, "?");
   begin
      if Q = 0 then
         return Target;
      else
         return Target (Target'First .. Q - 1);
      end if;
   end Path_Only;

   procedure Parse_Request_Line
     (Line : String; Method : out Unbounded_String; Target : out Unbounded_String; Valid : out Boolean)
   is
      First_Space : constant Natural := Index (Line, " ");
      Second_Space : Natural := 0;
   begin
      Valid := False;
      if First_Space = 0 then
         return;
      end if;
      Second_Space := Index (Line, " ", First_Space + 1);
      if Second_Space = 0 then
         return;
      end if;
      Method := To_Unbounded_String (Line (Line'First .. First_Space - 1));
      Target := To_Unbounded_String (Line (First_Space + 1 .. Second_Space - 1));
      Valid := True;
   end Parse_Request_Line;

   function Handle_JSON (Request_Body : String) return String is
      Root : JSON_Value;
      ID_Value : JSON_Value;
      Payload_Value : JSON_Value;
      ID : Long_Long_Integer;
   begin
      begin
         Root := Read (Request_Body);
      exception
         when others =>
            Metrics.Record_Error;
            Metrics.Record_Response (400);
            return Response (400, "{""error"":""invalid_json""}");
      end;

      if Kind (Root) /= JSON_Object_Type or else not Has_Field (Root, "id") or else not Has_Field (Root, "payload") then
         Metrics.Record_Error;
         Metrics.Record_Response (400);
         return Response (400, "{""error"":""invalid_request""}");
      end if;

      ID_Value := Get (Root, "id");
      Payload_Value := Get (Root, "payload");
      if Kind (ID_Value) /= JSON_Int_Type or else Kind (Payload_Value) /= JSON_String_Type then
         Metrics.Record_Error;
         Metrics.Record_Response (400);
         return Response (400, "{""error"":""invalid_request""}");
      end if;

      ID := Get (ID_Value);
      if ID < 0 or else ID > Max_Safe_Integer then
         Metrics.Record_Error;
         Metrics.Record_Response (400);
         return Response (400, "{""error"":""invalid_request""}");
      end if;

      declare
         Payload : constant String := Get (Payload_Value);
         Sum : constant U32 := Checksum (Payload);
      begin
         Metrics.Record_Response (200);
         return Response (200,
           "{""id"":" & Image (ID) & ",""len"":" & Trim (Natural'Image (Payload'Length), Both) &
           ",""checksum"":" & Image_U32 (Sum) & "}");
      end;
   exception
      when others =>
         Metrics.Record_Error;
         Metrics.Record_Response (400);
         return Response (400, "{""error"":""invalid_request""}");
   end Handle_JSON;

   procedure Handle_Connection (Socket : in out Socket_Type) is
      Channel : constant Stream_Access := Stream (Socket);
   begin
      loop
         declare
            Request_Line : constant String := Read_Line (Channel);
            Method : Unbounded_String;
            Target : Unbounded_String;
            Valid : Boolean;
            Content_Length : Natural := 0;
            Keep_Alive : Boolean := True;
         begin
            exit when Request_Line'Length = 0;
            Parse_Request_Line (Request_Line, Method, Target, Valid);

            loop
               declare
                  Header : constant String := Read_Line (Channel);
                  Lower : constant String := Ada.Characters.Handling.To_Lower (Header);
                  Colon : constant Natural := Index (Header, ":");
               begin
                  exit when Header'Length = 0;
                  if Colon > 0 and then Index (Lower, "content-length:") = Lower'First then
                     Content_Length := Natural'Value (Trim (Header (Colon + 1 .. Header'Last), Both));
                  elsif Colon > 0 and then Index (Lower, "connection:") = Lower'First then
                     declare
                        Value : constant String := Trim (Lower (Colon + 1 .. Lower'Last), Both);
                     begin
                        if Value = "close" then
                           Keep_Alive := False;
                        end if;
                     end;
                  end if;
               end;
            end loop;

            declare
               Request_Body : constant String := Read_Exact (Channel, Content_Length);
               Path : constant String := (if Valid then Path_Only (To_String (Target)) else "");
               Reply : Unbounded_String;
            begin
               if not Valid then
                  Reply := To_Unbounded_String (Response (404, "{""error"":""not_found""}"));
               elsif To_String (Method) = "GET" and then Path = "/health" then
                  Reply := To_Unbounded_String (Response (200,
                    "{""ok"":true,""active_connections"":null,""accepted_connections_total"":null,""closed_connections_total"":null" &
                    ",""active_requests"":" & Image (Metrics.Active_Requests) &
                    ",""requests_started_total"":" & Image (Metrics.Requests_Started) &
                    ",""responses_completed_total"":" & Image (Metrics.Responses_Completed) &
                    ",""total_errors"":" & Image (Metrics.Request_Errors) & "}"));
               elsif To_String (Method) = "GET" and then Path = "/runtime" then
                  Reply := To_Unbounded_String (Response (200, Runtime_JSON));
               elsif To_String (Method) = "POST" and then Path = "/json" then
                  Metrics.Start_Request;
                  Reply := To_Unbounded_String (Handle_JSON (Request_Body));
                  Metrics.Finish_Request;
               else
                  Reply := To_Unbounded_String (Response (404, "{""error"":""not_found""}"));
               end if;

               Write_String (Channel, To_String (Reply));
               exit when not Keep_Alive;
            end;
         end;
      end loop;
   exception
      when Ada.IO_Exceptions.End_Error =>
         null;
      when others =>
         null;
   end Handle_Connection;

   task type Connection_Task is
      entry Start (Client : in Socket_Type);
   end Connection_Task;

   task body Connection_Task is
      Client_Socket : Socket_Type;
   begin
      accept Start (Client : in Socket_Type) do
         Client_Socket := Client;
      end Start;
      Handle_Connection (Client_Socket);
      Close_Socket (Client_Socket);
   exception
      when others =>
         begin
            Close_Socket (Client_Socket);
         exception
            when others => null;
         end;
   end Connection_Task;

   task type Listener_Task is
      entry Start (Bind_Host : in String; Bind_Port : in Port_Type);
   end Listener_Task;

   task body Listener_Task is
      Host : Unbounded_String;
      Port : Port_Type;
      Server_Socket : Socket_Type;
      Client_Socket : Socket_Type;
      Address : Sock_Addr_Type;
      Worker : access Connection_Task;
   begin
      accept Start (Bind_Host : in String; Bind_Port : in Port_Type) do
         Host := To_Unbounded_String (Bind_Host);
         Port := Bind_Port;
      end Start;

      Create_Socket (Server_Socket);
      Set_Socket_Option (Server_Socket, Socket_Level, (Reuse_Address, True));
      Bind_Socket (Server_Socket,
        (Family => Family_Inet, Addr => Inet_Addr (To_String (Host)), Port => Port));
      Listen_Socket (Server_Socket, 65_535);
      Ada.Text_IO.Put_Line ("Ada GNAT.Sockets JSON server listening on http://" & To_String (Host) & ":" & Image (Long_Long_Integer (Port)));

      loop
         Accept_Socket (Server_Socket, Client_Socket, Address);
         Worker := new Connection_Task;
         Worker.Start (Client_Socket);
      end loop;
   exception
      when E : others =>
         Ada.Text_IO.Put_Line (Ada.Text_IO.Standard_Error,
           "ada-gnat listener failed: " & Ada.Exceptions.Exception_Message (E));
   end Listener_Task;

   task type Metrics_Task is
      entry Start (Activity_Path : in String; Runtime_Path : in String);
   end Metrics_Task;

   task body Metrics_Task is
      Activity_File : Ada.Text_IO.File_Type;
      Runtime_File : Ada.Text_IO.File_Type;
      Activity_Enabled : Boolean := False;
      Runtime_Enabled : Boolean := False;

      procedure Open_Append (File : in out Ada.Text_IO.File_Type; Path : String; Enabled : out Boolean) is
      begin
         Enabled := False;
         if Path'Length = 0 then
            return;
         end if;
         begin
            Ada.Text_IO.Open (File, Ada.Text_IO.Append_File, Path);
         exception
            when Ada.Text_IO.Name_Error =>
               Ada.Text_IO.Create (File, Ada.Text_IO.Append_File, Path);
         end;
         Enabled := True;
      end Open_Append;
   begin
      accept Start (Activity_Path : in String; Runtime_Path : in String) do
         Open_Append (Activity_File, Activity_Path, Activity_Enabled);
         Open_Append (Runtime_File, Runtime_Path, Runtime_Enabled);
      end Start;

      if Activity_Enabled then
         Ada.Text_IO.Put_Line (Activity_File, Activity_JSON);
         Ada.Text_IO.Flush (Activity_File);
      end if;
      if Runtime_Enabled then
         Ada.Text_IO.Put_Line (Runtime_File, Runtime_JSON);
         Ada.Text_IO.Flush (Runtime_File);
      end if;

      loop
         delay 1.0;
         if Activity_Enabled then
            Ada.Text_IO.Put_Line (Activity_File, Activity_JSON);
            Ada.Text_IO.Flush (Activity_File);
         end if;
         if Runtime_Enabled then
            Ada.Text_IO.Put_Line (Runtime_File, Runtime_JSON);
            Ada.Text_IO.Flush (Runtime_File);
         end if;
      end loop;
   end Metrics_Task;

   Host : constant String := Env ("HOST", "127.0.0.1");
   Ports_Value : constant String := Env ("PORTS", Env ("PORT", "8080"));
   Ports : constant Port_Array := Parse_Ports (Ports_Value);
   Listeners : array (Ports'Range) of access Listener_Task;
   Sampler : Metrics_Task;
begin
   Initialize;
   Sampler.Start (Env ("ACTIVITY_METRICS_PATH"), Env ("RUNTIME_METRICS_PATH"));
   for I in Ports'Range loop
      Listeners (I) := new Listener_Task;
      Listeners (I).Start (Host, Ports (I));
   end loop;

   loop
      delay 3600.0;
   end loop;
end Server;
