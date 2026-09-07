unit MCPServer.Tool.Result;

interface

uses
  System.SysUtils,
  System.Classes,
  System.JSON,
  System.Generics.Collections,
  MCPServer.Types,
  MCPServer.ContentBlocks;

type
  TMCPToolResult = class
  private
    FContent: TJSONArray;
    FPendingAnnotations: TJSONObject;
    FStructuredContent: TJSONValue;
    FMeta: TJSONObject;
    FIsError: Boolean;
    procedure AddBlock(const Block: TJSONObject);
    function BuildContent(Era: TMCPProtocolEra): TJSONArray;
  public
    constructor Create;
    destructor Destroy; override;

    function AddText(const Text: string): TMCPToolResult;
    function AddImage(const Data: TBytes; const MimeType: string): TMCPToolResult; overload;
    function AddImage(const Base64Data, MimeType: string): TMCPToolResult; overload;
    function AddAudio(const Data: TBytes; const MimeType: string): TMCPToolResult; overload;
    function AddAudio(const Base64Data, MimeType: string): TMCPToolResult; overload;
    function AddResourceLink(const Uri, Name: string; const Description: string = '';
      const MimeType: string = ''): TMCPToolResult;
    function AddEmbeddedText(const Uri, MimeType, Text: string): TMCPToolResult;
    function AddEmbeddedBlob(const Uri, MimeType: string; const Data: TBytes): TMCPToolResult;
    function WithAnnotations(const Annotations: TJSONObject): TMCPToolResult;
    function SetStructuredContent(const Value: TJSONValue): TMCPToolResult;
    function SetMeta(const Meta: TJSONObject): TMCPToolResult;
    function SetError(const Message: string): TMCPToolResult;

    class function Text(const Text: string): TMCPToolResult;
    class function Error(const Message: string): TMCPToolResult;

    function ToJson(Era: TMCPProtocolEra): TJSONObject;

    property IsError: Boolean read FIsError write FIsError;
    property Content: TJSONArray read FContent;
    property StructuredContent: TJSONValue read FStructuredContent;
  end;

implementation

{ TMCPToolResult }

constructor TMCPToolResult.Create;
begin
  inherited Create;
  FContent := TJSONArray.Create;
end;

destructor TMCPToolResult.Destroy;
begin
  FPendingAnnotations.Free;
  FContent.Free;
  FStructuredContent.Free;
  FMeta.Free;
  inherited;
end;

function TMCPToolResult.AddText(const Text: string): TMCPToolResult;
begin
  AddBlock(TMCPContentBlock.Text(Text));
  Result := Self;
end;

function TMCPToolResult.AddImage(const Data: TBytes; const MimeType: string): TMCPToolResult;
begin
  Result := AddImage(TMCPContentBlock.EncodeBlob(Data), MimeType);
end;

function TMCPToolResult.AddImage(const Base64Data, MimeType: string): TMCPToolResult;
begin
  AddBlock(TMCPContentBlock.Image(Base64Data, MimeType));
  Result := Self;
end;

function TMCPToolResult.AddAudio(const Data: TBytes; const MimeType: string): TMCPToolResult;
begin
  Result := AddAudio(TMCPContentBlock.EncodeBlob(Data), MimeType);
end;

function TMCPToolResult.AddAudio(const Base64Data, MimeType: string): TMCPToolResult;
begin
  AddBlock(TMCPContentBlock.Audio(Base64Data, MimeType));
  Result := Self;
end;

function TMCPToolResult.AddResourceLink(const Uri, Name, Description, MimeType: string): TMCPToolResult;
begin
  AddBlock(TMCPContentBlock.ResourceLink(Uri, Name, Description, MimeType));
  Result := Self;
end;

function TMCPToolResult.AddEmbeddedText(const Uri, MimeType, Text: string): TMCPToolResult;
begin
  AddBlock(TMCPContentBlock.EmbeddedText(Uri, MimeType, Text));
  Result := Self;
end;

function TMCPToolResult.AddEmbeddedBlob(const Uri, MimeType: string; const Data: TBytes): TMCPToolResult;
begin
  AddBlock(TMCPContentBlock.EmbeddedBlob(Uri, MimeType, TMCPContentBlock.EncodeBlob(Data)));
  Result := Self;
end;

procedure TMCPToolResult.AddBlock(const Block: TJSONObject);
begin
  FContent.AddElement(Block);
  if Assigned(FPendingAnnotations) then
  begin
    Block.AddPair('annotations', FPendingAnnotations);
    FPendingAnnotations := nil;
  end;
end;

function TMCPToolResult.WithAnnotations(const Annotations: TJSONObject): TMCPToolResult;
begin
  const HasBlock = (FContent.Count > 0);
  if HasBlock then
    TJSONObject(FContent.Items[FContent.Count - 1]).AddPair('annotations', Annotations)
  else
  begin
    FPendingAnnotations.Free;
    FPendingAnnotations := Annotations;
  end;
  Result := Self;
end;

function TMCPToolResult.SetStructuredContent(const Value: TJSONValue): TMCPToolResult;
begin
  FStructuredContent.Free;
  FStructuredContent := Value;
  Result := Self;
end;

function TMCPToolResult.SetMeta(const Meta: TJSONObject): TMCPToolResult;
begin
  FMeta.Free;
  FMeta := Meta;
  Result := Self;
end;

function TMCPToolResult.SetError(const Message: string): TMCPToolResult;
begin
  AddText(Message);
  FIsError := True;
  Result := Self;
end;

class function TMCPToolResult.Text(const Text: string): TMCPToolResult;
begin
  Result := TMCPToolResult.Create.AddText(Text);
end;

class function TMCPToolResult.Error(const Message: string): TMCPToolResult;
begin
  Result := TMCPToolResult.Create.SetError(Message);
end;

function TMCPToolResult.BuildContent(Era: TMCPProtocolEra): TJSONArray;
begin
  Result := TJSONArray(FContent.Clone);
  if (Result.Count = 0) and Assigned(FStructuredContent) then
  begin
    var Block := TJSONObject.Create;
    Block.AddPair('type', 'text');
    Block.AddPair('text', FStructuredContent.ToJSON);
    Result.AddElement(Block);
  end;
end;

function TMCPToolResult.ToJson(Era: TMCPProtocolEra): TJSONObject;
begin
  Result := TJSONObject.Create;
  try
    Result.AddPair('content', BuildContent(Era));

    if Assigned(FStructuredContent)
      and ((Era = TMCPProtocolEra.Modern) or (FStructuredContent is TJSONObject)) then
      Result.AddPair('structuredContent', FStructuredContent.Clone as TJSONValue);

    if FIsError then
      Result.AddPair('isError', TJSONBool.Create(True));

    if Assigned(FMeta) then
      Result.AddPair('_meta', TJSONObject(FMeta.Clone));
  except
    Result.Free;
    raise;
  end;
end;

end.
