unit MCPClient.Interfaces;

// The seams a host implements or consumes. IMCPClientAuth supplies and refreshes a bearer
// token, IMCPClientSink receives the notifications that arrive while a call is in flight,
// and IMCPClient is the whole client. The cancellation check is a TFunc<Boolean> rather
// than an interface so that this library never learns about a host's cancellation type.

interface

uses
  System.SysUtils,
  System.JSON,
  MCPClient.Types;

type
  IMCPClientAuth = interface
    ['{7C1D2E3F-4A5B-4C6D-8E9F-0A1B2C3D4E5F}']
    function GetToken: string;
    function Refresh: string;
  end;

  IMCPClientSink = interface
    ['{4B6D8FA0-2C3E-4D5F-8A1B-6C7D8E9F0A1B}']
    procedure Progress(const Token: string; const Progress, Total: Double; const Message: string);
    procedure LogMessage(const Level, Logger, DataJson: string);
  end;

  IMCPClient = interface
    ['{2E4A6C8E-0B1D-4F3A-9C5E-7D8F0A1B2C3D}']
    procedure Connect;
    procedure Close;
    function IsConnected: Boolean;
    function Era: TMCPClientEra;
    function ProtocolVersion: string;
    function ServerUrl: string;
    function ServerInfoJson: string;
    function ListTools: TArray<TMCPRemoteTool>;
    procedure RefreshTools;
    function CallTool(const Name: string; const Arguments: TJSONObject): TMCPToolCallOutcome;
    procedure SetInputResponder(const Responder: TMCPInputResponder);
    procedure SetSink(const Sink: IMCPClientSink);
    procedure SetCancellationCheck(const Check: TFunc<Boolean>);
  end;

implementation

end.
