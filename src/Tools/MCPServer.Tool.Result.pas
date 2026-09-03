unit MCPServer.Tool.Result;

interface

uses
  System.SysUtils,
  System.Classes,
  System.JSON,
  MCPServer.Types;

type
  /// Builds a tools/call result: content blocks of every kind, optional
  /// structured content, the error flag and result metadata. A tool returns
  /// the instance from Execute (as a TValue); the tools manager serialises it
  /// for the era of the request and frees it.
  TMCPToolResult = class
  private
    FContent: TJSONArray;
    FStructuredContent: TJSONValue;
    FMeta: TJSONObject;
    FIsError: Boolean;
    function AddBlock(const BlockType: string): TJSONObject;
    function BuildContent(Era: TMCPProtocolEra): TJSONArray;
  public
    constructor Create;
    destructor Destroy; override;

    function AddText(const Text: string): TMCPToolResult;
    /// Data is the raw content; it is Base64-encoded here.
    function AddImage(const Data: TBytes; const MimeType: string): TMCPToolResult; overload;
    function AddImage(const Base64Data, MimeType: string): TMCPToolResult; overload;
    function AddAudio(const Data: TBytes; const MimeType: string): TMCPToolResult; overload;
    function AddAudio(const Base64Data, MimeType: string): TMCPToolResult; overload;
    function AddResourceLink(const Uri, Name: string; const Description: string = '';
      const MimeType: string = ''): TMCPToolResult;
    function AddEmbeddedText(const Uri, MimeType, Text: string): TMCPToolResult;
    function AddEmbeddedBlob(const Uri, MimeType: string; const Data: TBytes): TMCPToolResult;
    /// Annotations for the block added last (audience, priority, lastModified).
    function WithAnnotations(const Annotations: TJSONObject): TMCPToolResult;
    /// Takes ownership. Any JSON value; the initialize-based revisions only
    /// carry it when it is an object, and a text block with the compact JSON
    /// is added when no other content exists.
    function SetStructuredContent(const Value: TJSONValue): TMCPToolResult;
    /// Takes ownership of the result-level _meta object.
    function SetMeta(const Meta: TJSONObject): TMCPToolResult;
    function SetError(const Message: string): TMCPToolResult;

    class function Text(const Text: string): TMCPToolResult;
    class function Error(const Message: string): TMCPToolResult;

    /// The CallToolResult object for the era; the caller owns it.
    function ToJson(Era: TMCPProtocolEra): TJSONObject;

    property IsError: Boolean read FIsError write FIsError;
    property Content: TJSONArray read FContent;
    property StructuredContent: TJSONValue read FStructuredContent;
  end;

  /// Base64 without line breaks, as the schema requires for blobs.
  function EncodeBase64Blob(const Data: TBytes): string;

implementation

uses
  System.NetEncoding;

function EncodeBase64Blob(const Data: TBytes): string;
begin
  var Encoding := TBase64Encoding.Create(0);
  try
    Result := Encoding.EncodeBytesToString(Data);
  finally
    Encoding.Free;
  end;
end;

{ TMCPToolResult }

constructor TMCPToolResult.Create;
begin
  inherited Create;
  FContent := TJSONArray.Create;
end;

destructor TMCPToolResult.Destroy;
begin
  FContent.Free;
  FStructuredContent.Free;
  FMeta.Free;
  inherited;
end;

function TMCPToolResult.AddBlock(const BlockType: string): TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('type', BlockType);
  FContent.AddElement(Result);
end;

function TMCPToolResult.AddText(const Text: string): TMCPToolResult;
begin
  AddBlock('text').AddPair('text', Text);
  Result := Self;
end;

function TMCPToolResult.AddImage(const Data: TBytes; const MimeType: string): TMCPToolResult;
begin
  Result := AddImage(EncodeBase64Blob(Data), MimeType);
end;

function TMCPToolResult.AddImage(const Base64Data, MimeType: string): TMCPToolResult;
begin
  var Block := AddBlock('image');
  Block.AddPair('data', Base64Data);
  Block.AddPair('mimeType', MimeType);
  Result := Self;
end;

function TMCPToolResult.AddAudio(const Data: TBytes; const MimeType: string): TMCPToolResult;
begin
  Result := AddAudio(EncodeBase64Blob(Data), MimeType);
end;

function TMCPToolResult.AddAudio(const Base64Data, MimeType: string): TMCPToolResult;
begin
  var Block := AddBlock('audio');
  Block.AddPair('data', Base64Data);
  Block.AddPair('mimeType', MimeType);
  Result := Self;
end;

function TMCPToolResult.AddResourceLink(const Uri, Name, Description, MimeType: string): TMCPToolResult;
begin
  var Block := AddBlock('resource_link');
  Block.AddPair('uri', Uri);
  Block.AddPair('name', Name);
  if Description <> '' then
    Block.AddPair('description', Description);
  if MimeType <> '' then
    Block.AddPair('mimeType', MimeType);
  Result := Self;
end;

function TMCPToolResult.AddEmbeddedText(const Uri, MimeType, Text: string): TMCPToolResult;
begin
  var Resource := TJSONObject.Create;
  Resource.AddPair('uri', Uri);
  Resource.AddPair('mimeType', MimeType);
  Resource.AddPair('text', Text);
  AddBlock('resource').AddPair('resource', Resource);
  Result := Self;
end;

function TMCPToolResult.AddEmbeddedBlob(const Uri, MimeType: string; const Data: TBytes): TMCPToolResult;
begin
  var Resource := TJSONObject.Create;
  Resource.AddPair('uri', Uri);
  Resource.AddPair('mimeType', MimeType);
  Resource.AddPair('blob', EncodeBase64Blob(Data));
  AddBlock('resource').AddPair('resource', Resource);
  Result := Self;
end;

function TMCPToolResult.WithAnnotations(const Annotations: TJSONObject): TMCPToolResult;
begin
  if FContent.Count = 0 then
  begin
    Annotations.Free;
    raise EInvalidOperation.Create('WithAnnotations needs a content block to attach to');
  end;
  TJSONObject(FContent.Items[FContent.Count - 1]).AddPair('annotations', Annotations);
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
  // The schema requires content; structured-only results get the JSON as text.
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

    // 2025-06-18 and 2025-11-25 define structuredContent as an object only.
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
