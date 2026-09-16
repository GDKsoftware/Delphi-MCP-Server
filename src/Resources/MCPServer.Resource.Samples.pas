unit MCPServer.Resource.Samples;

interface

uses
  System.SysUtils,
  MCPServer.Types,
  MCPServer.Resource.Base;

type
  TStaticText = class
  private
    FContent: string;
  public
    property Content: string read FContent write FContent;
  end;

  TStaticTextResource = class(TMCPResourceBase<TStaticText>)
  protected
    function GetResourceData: TStaticText; override;
  public
    constructor Create; override;
  end;

  TStaticBinaryResource = class(TMCPResourceBase<TStaticText>, IMCPBinaryResource)
  protected
    function GetResourceData: TStaticText; override;
  public
    constructor Create; override;
    function ReadBinary: TBytes;
  end;

  TTemplateData = class
  private
    FId: string;
    FTemplateTest: Boolean;
    FData: string;
  public
    property Id: string read FId write FId;
    property TemplateTest: Boolean read FTemplateTest write FTemplateTest;
    property Data: string read FData write FData;
  end;

  TTemplateDataResource = class(TMCPResourceBase<TTemplateData>)
  private
    FId: string;
  protected
    function GetResourceData: TTemplateData; override;
  public
    constructor CreateForId(const AUri, AId: string);
  end;

  TTemplateDataResourceTemplate = class(TMCPResourceTemplateBase)
  public
    constructor Create; override;
    function CreateResource(const URI: string; Vars: TMCPTemplateVars): IMCPResource; override;
  end;

implementation

uses
  System.NetEncoding,
  MCPServer.Registration,
  MCPServer.Tool.ContentSamples;

const
  MIME_TYPE_JSON = 'application/json';
  URI_STATIC_BINARY = 'test://static-binary';
  TEMPLATE_DATA_TITLE = 'Template data';
  URI_TEMPLATE_DATA = 'test://template/{id}/data';
  SAMPLE_RESOURCE_TTL_MS = 3600000;

{ TStaticTextResource }

constructor TStaticTextResource.Create;
begin
  inherited;
  FURI := SAMPLE_TEXT_RESOURCE_URI;
  FName := 'Static text';
  FTitle := 'Static text resource';
  FDescription := 'A fixed text resource';
  FMimeType := 'text/plain';
  FTtlMs := SAMPLE_RESOURCE_TTL_MS;
  FCacheScope := MCP_CACHE_SCOPE_PUBLIC;
end;

function TStaticTextResource.GetResourceData: TStaticText;
begin
  Result := TStaticText.Create;
  Result.Content := SAMPLE_TEXT_RESOURCE_CONTENT;
end;

{ TStaticBinaryResource }

constructor TStaticBinaryResource.Create;
begin
  inherited;
  FURI := URI_STATIC_BINARY;
  FName := 'Static binary';
  FTitle := 'Static binary resource';
  FDescription := 'A fixed PNG image';
  FMimeType := 'image/png';
  FTtlMs := SAMPLE_RESOURCE_TTL_MS;
  FCacheScope := MCP_CACHE_SCOPE_PUBLIC;
end;

function TStaticBinaryResource.GetResourceData: TStaticText;
begin
  Result := TStaticText.Create;
  Result.Content := SAMPLE_PNG_BASE64;
end;

function TStaticBinaryResource.ReadBinary: TBytes;
begin
  Result := TNetEncoding.Base64.DecodeStringToBytes(SAMPLE_PNG_BASE64);
end;

{ TTemplateDataResource }

constructor TTemplateDataResource.CreateForId(const AUri, AId: string);
begin
  inherited Create;
  FId := AId;
  FURI := AUri;
  FName := TEMPLATE_DATA_TITLE;
  FDescription := 'Data keyed by the id captured from the template';
  FMimeType := MIME_TYPE_JSON;
end;

function TTemplateDataResource.GetResourceData: TTemplateData;
begin
  Result := TTemplateData.Create;
  Result.Id := FId;
  Result.TemplateTest := True;
  Result.Data := 'Data for ID: ' + FId;
end;

{ TTemplateDataResourceTemplate }

constructor TTemplateDataResourceTemplate.Create;
begin
  inherited;
  FUriTemplate := URI_TEMPLATE_DATA;
  FName := TEMPLATE_DATA_TITLE;
  FDescription := 'Data keyed by an id path segment';
  FMimeType := MIME_TYPE_JSON;
end;

function TTemplateDataResourceTemplate.CreateResource(const URI: string; Vars: TMCPTemplateVars): IMCPResource;
begin
  Result := TTemplateDataResource.CreateForId(URI, Vars['id']);
end;

initialization
  TMCPRegistry.RegisterResource(SAMPLE_TEXT_RESOURCE_URI,
    function: IMCPResource
    begin
      Result := TStaticTextResource.Create;
    end);
  TMCPRegistry.RegisterResource(URI_STATIC_BINARY,
    function: IMCPResource
    begin
      Result := TStaticBinaryResource.Create;
    end);
  TMCPRegistry.RegisterResourceTemplate(URI_TEMPLATE_DATA,
    function: IMCPResourceTemplate
    begin
      Result := TTemplateDataResourceTemplate.Create;
    end);

end.
