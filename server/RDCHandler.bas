B4J=true
Group=Default Group
ModulesStructureVersion=1
Type=Class
Version=10
@EndOfDesignText@
'Handler class
Sub Class_Globals
	Private DateTimeMethods As Map
End Sub

Public Sub Initialize
	DateTimeMethods = CreateMap(91: "getDate", 92: "getTime", 93: "getTimestamp")
End Sub

Sub Handle (req As ServletRequest, resp As ServletResponse)
	Dim start As Long = DateTime.Now
	Dim q As String
	Dim in As InputStream = req.InputStream
	Dim method As String = req.GetParameter("method")
	Dim con As SQL
	Try
		con = Main.rdcConnector1.GetConnection
		If method = "query" Then
			q = ExecuteQuery(con, in, resp)
		Else if method = "batch" Then
			q = ExecuteBatch(con, in, resp)
		Else If method = "login" Then
			q = ExecuteLogin(con, in, resp)
		Else
			Log("Unknown method: " & method)
			resp.SendError(500, "unknown method")
		End If
	Catch
		Log(LastException)
		resp.SendError(500, LastException.Message)
	End Try
	If con <> Null And con.IsInitialized Then con.Close
	Log($"Command: ${q}, took: ${DateTime.Now - start}ms, client=${req.RemoteAddress}"$)
End Sub

Private Sub ExecuteLogin (con As SQL, in As InputStream, resp As ServletResponse) As String
	Dim ser As B4XSerializator
	Dim m As Map = ser.ConvertBytesToObject(Bit.InputStreamToBytes(in))
	'Log(m)
	'Dim cmd As DBCommand = m.Get("command")
	
	Dim res As DBResult
	res.Initialize
	res.Tag = Null 'without this the Tag properly will not be serializable.
	res.columns.Initialize
	res.Rows.Initialize
	res.Message = "Success"
	res.Error = Null
	
	Dim qry As String = "SELECT name, admin, active FROM users WHERE email = ? AND password = ?"
	Dim rs As ResultSet = con.ExecQuery2(qry, Array(m.Get("email"), m.Get("password")))
	Do While rs.NextRow
		Dim expiry As Long = DateTime.Now + 600000
		Dim session As String = "session" & expiry
		Dim qry As String = "INSERT INTO sessions (session, expiry) VALUES (?, ?)"
		con.ExecNonQuery2(qry, Array(session, expiry))
		res.columns.Put("session", 0)
		res.columns.Put("expiry", 1)
		Dim row(2) As Object
		row(0) = session
		row(1) = expiry
		res.Rows.Add(row)
	Loop
	rs.Close

	' return DBResult data in bytes
	Dim data() As Byte = ser.ConvertObjectToBytes(res)
	resp.OutputStream.WriteBytes(data, 0, data.Length)
	Return "login"
End Sub

Private Sub CheckSession (con As SQL, session As String) As Boolean
	Dim qry As String = "SELECT expiry FROM sessions WHERE session = ?"
	Dim rs As ResultSet = con.ExecQuery2(qry, Array(session))
	Dim found As Boolean
	Do While rs.NextRow
		found = True
	Loop
	rs.Close
	Return found
End Sub

Private Sub ExecuteQuery (con As SQL, in As InputStream, resp As ServletResponse) As String
	Dim ser As B4XSerializator
	Dim m As Map = ser.ConvertBytesToObject(Bit.InputStreamToBytes(in))
	Dim cmd As DBCommand = m.Get("command")
	Dim limit As Int = m.Get("limit")
	Dim session As String = m.Get("session")
	' Check session
	'Log(session)
	If session = "null" Then
		Log("Invalid session")
		Dim data() As Byte = ser.ConvertObjectToBytes(Main.CreateDBResult(Null, CreateMap(), Array(), "", "Invalid session"))
		resp.OutputStream.WriteBytes(data, 0, data.Length)
		Return "query: " & cmd.Name
	End If
	If CheckSession(con, session) = False Then
		Log("Invalid session")
		Dim data() As Byte = ser.ConvertObjectToBytes(Main.CreateDBResult(Null, CreateMap(), Array(), "", "Invalid session"))
		resp.OutputStream.WriteBytes(data, 0, data.Length)
		Return "query: " & cmd.Name
	End If
	
	Dim rs As ResultSet = con.ExecQuery2(Main.rdcConnector1.GetCommand(cmd.Name), cmd.Parameters)
	If limit <= 0 Then limit = 0x7fffffff 'max int
	Dim jrs As JavaObject = rs
	Dim rsmd As JavaObject = jrs.RunMethod("getMetaData", Null)
	Dim cols As Int = rs.ColumnCount
	Dim res As DBResult
	res.Initialize
	res.columns.Initialize
	res.Tag = Null 'without this the Tag properly will not be serializable.
	For i = 0 To cols - 1
		res.columns.Put(rs.GetColumnName(i), i)
	Next
	res.Rows.Initialize
	Do While rs.NextRow And limit > 0
		Dim row(cols) As Object
		For i = 0 To cols - 1
			Dim ct As Int = rsmd.RunMethod("getColumnType", Array(i + 1))
			'check whether it is a blob field
			If ct = -2 Or ct = 2004 Or ct = -3 Or ct = -4 Then
				row(i) = rs.GetBlob2(i)
			Else If ct = 2005 Then
				row(i) = rs.GetString2(i)
			Else if ct = 2 Or ct = 3 Then
				row(i) = rs.GetDouble2(i)
			Else If DateTimeMethods.ContainsKey(ct) Then
				Dim SQLTime As JavaObject = jrs.RunMethodJO(DateTimeMethods.Get(ct), Array(i + 1))
				If SQLTime.IsInitialized Then
					row(i) = SQLTime.RunMethod("getTime", Null)
				Else
					row(i) = Null
				End If
			Else
				row(i) = jrs.RunMethod("getObject", Array(i + 1))
			End If
		Next
		res.Rows.Add(row)
	Loop
	rs.Close
	res.Message = "Success"
	res.Error = Null
	
	' return DBResult data in bytes
	Dim data() As Byte = ser.ConvertObjectToBytes(res)
	resp.OutputStream.WriteBytes(data, 0, data.Length)
	Return "query: " & cmd.Name
End Sub

Private Sub ExecuteBatch (con As SQL, in As InputStream, resp As ServletResponse) As String
	Dim ser As B4XSerializator
	Dim m As Map = ser.ConvertBytesToObject(Bit.InputStreamToBytes(in))
	Dim commands As List = m.Get("commands")
	Dim res As DBResult
	res.Initialize
	res.columns = CreateMap("AffectedRows (N/A)": 0)
	res.Rows.Initialize
	res.Tag = Null
	Try
		con.BeginTransaction
		For Each cmd As DBCommand In commands
			Log($"Command: query: ${cmd.Name}, Parameters=${cmd.Parameters.As(List)}"$)
			con.ExecNonQuery2(Main.rdcConnector1.GetCommand(cmd.Name), cmd.Parameters)
		Next
		res.Rows.Add(Array As Object(0))
		con.TransactionSuccessful
	Catch
		con.Rollback
		Log(LastException)
		resp.SendError(500, LastException.Message)
	End Try
	Dim data() As Byte = ser.ConvertObjectToBytes(res)
	resp.OutputStream.WriteBytes(data, 0, data.Length)
	Return $"batch (size=${commands.Size})"$
End Sub