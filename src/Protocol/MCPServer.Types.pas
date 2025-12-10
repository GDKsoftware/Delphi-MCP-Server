unit MCPServer.Types;

interface

uses
  System.SysUtils,
  System.JSON,
  System.Rtti;

const
  MCP_PROTOCOL_VERSION = '2025-06-18';

type
  OptionalAttribute = class(TCustomAttribute)
  end;

  SchemaDescriptionAttribute = class(TCustomAttribute)
  private
    FDescription: string;
  public
    constructor Create(const ADescription: string);
    property Description: string read FDescription;
  end;

  SchemaEnumAttribute = class(TCustomAttribute)
  private
    FValues: TArray<string>;
  public
    constructor Create(const AValues: array of string); overload;
    constructor Create(const AValue1: string); overload;
    constructor Create(const AValue1, AValue2: string); overload;
    constructor Create(const AValue1, AValue2, AValue3: string); overload;
    constructor Create(const AValue1, AValue2, AValue3, AValue4: string); overload;
    property Values: TArray<string> read FValues;
  end;

  TMCPToolsCapability = class;
  
  IMCPCapabilityManager = interface
    ['{E5F7C3A1-8B4D-4F6E-9C2A-1D3E5F7A9B8C}']
    function GetCapabilityName: string;
    function HandlesMethod(const Method: string): Boolean;
    function ExecuteMethod(const Method: string; const Params: TJSONObject): TValue;
  end;
  
  IMCPManagerRegistry = interface
    ['{A2B4C6D8-1E3F-5A7B-9C8D-2F4E6A8C0B2D}']
    procedure RegisterManager(const Manager: IMCPCapabilityManager);
    function GetManagerForMethod(const Method: string): IMCPCapabilityManager;
  end;
  
  TMCPCapabilities = class
  private
    FTools: TMCPToolsCapability;
    FLogging: TJSONObject;
  public
    constructor Create;
    destructor Destroy; override;
    property Tools: TMCPToolsCapability read FTools write FTools;
    property Logging: TJSONObject read FLogging write FLogging;
  end;

  TMCPToolsCapability = class
  private
    FSupportsProgress: Boolean;
    FSupportsCancellation: Boolean;
  public
    constructor Create;
    property SupportsProgress: Boolean read FSupportsProgress write FSupportsProgress;
    property SupportsCancellation: Boolean read FSupportsCancellation write FSupportsCancellation;
  end;

  TMCPInitializeResponse = class
  private
    FProtocolVersion: string;
    FCapabilities: TMCPCapabilities;
  public
    constructor Create;
    destructor Destroy; override;
    property ProtocolVersion: string read FProtocolVersion write FProtocolVersion;
    property Capabilities: TMCPCapabilities read FCapabilities write FCapabilities;
  end;

  TMCPPingResponse = class
  private
    FStatus: string;
    FTimestamp: string;
  public
    property Status: string read FStatus write FStatus;
    property Timestamp: string read FTimestamp write FTimestamp;
  end;

  TMCPTool = class
  private
    FName: string;
    FTitle: string;
    FDescription: string;
    FInputSchema: string;
  public
    property Name: string read FName write FName;
    property Title: string read FTitle write FTitle;
    property Description: string read FDescription write FDescription;
    property InputSchema: string read FInputSchema write FInputSchema;
  end;

  TMCPToolsResponse = class
  private
    FTools: TArray<TMCPTool>;
  public
    property Tools: TArray<TMCPTool> read FTools write FTools;
  end;

implementation

{ SchemaDescriptionAttribute }

constructor SchemaDescriptionAttribute.Create(const ADescription: string);
begin
  inherited Create;
  FDescription := ADescription;
end;

{ SchemaEnumAttribute }

constructor SchemaEnumAttribute.Create(const AValues: array of string);
begin
  inherited Create;
  SetLength(FValues, Length(AValues));
  for var I := 0 to High(AValues) do
    FValues[I] := AValues[I];
end;

constructor SchemaEnumAttribute.Create(const AValue1: string);
begin
  inherited Create;
  SetLength(FValues, 1);
  FValues[0] := AValue1;
end;

constructor SchemaEnumAttribute.Create(const AValue1, AValue2: string);
begin
  inherited Create;
  SetLength(FValues, 2);
  FValues[0] := AValue1;
  FValues[1] := AValue2;
end;

constructor SchemaEnumAttribute.Create(const AValue1, AValue2, AValue3: string);
begin
  inherited Create;
  SetLength(FValues, 3);
  FValues[0] := AValue1;
  FValues[1] := AValue2;
  FValues[2] := AValue3;
end;

constructor SchemaEnumAttribute.Create(const AValue1, AValue2, AValue3, AValue4: string);
begin
  inherited Create;
  SetLength(FValues, 4);
  FValues[0] := AValue1;
  FValues[1] := AValue2;
  FValues[2] := AValue3;
  FValues[3] := AValue4;
end;

{ TMCPInitializeResponse }

constructor TMCPInitializeResponse.Create;
begin
  inherited;
  FCapabilities := TMCPCapabilities.Create;
end;

destructor TMCPInitializeResponse.Destroy;
begin
  FCapabilities.Free;
  inherited;
end;

{ TMCPCapabilities }

constructor TMCPCapabilities.Create;
begin
  inherited;
  FTools := TMCPToolsCapability.Create;
  FLogging := TJSONObject.Create;
end;

destructor TMCPCapabilities.Destroy;
begin
  FTools.Free;
  FLogging.Free;
  inherited;
end;

{ TMCPToolsCapability }

constructor TMCPToolsCapability.Create;
begin
  inherited;
  FSupportsProgress := False;
  FSupportsCancellation := False;
end;

end.