unit MCPServer.ContentBlocks;

interface

uses
  System.SysUtils,
  System.JSON;

function CreateTextBlock(const Text: string): TJSONObject;
function CreateImageBlock(const Base64Data, MimeType: string): TJSONObject;
function CreateAudioBlock(const Base64Data, MimeType: string): TJSONObject;
function CreateResourceLinkBlock(const Uri, Name: string; const Description: string = '';
  const MimeType: string = ''): TJSONObject;
function CreateEmbeddedTextBlock(const Uri, MimeType, Text: string): TJSONObject;
function CreateEmbeddedBlobBlock(const Uri, MimeType, Base64Blob: string): TJSONObject;

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

function CreateTextBlock(const Text: string): TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('type', 'text');
  Result.AddPair('text', Text);
end;

function CreateImageBlock(const Base64Data, MimeType: string): TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('type', 'image');
  Result.AddPair('data', Base64Data);
  Result.AddPair('mimeType', MimeType);
end;

function CreateAudioBlock(const Base64Data, MimeType: string): TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('type', 'audio');
  Result.AddPair('data', Base64Data);
  Result.AddPair('mimeType', MimeType);
end;

function CreateResourceLinkBlock(const Uri, Name, Description, MimeType: string): TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('type', 'resource_link');
  Result.AddPair('uri', Uri);
  Result.AddPair('name', Name);
  if Description <> '' then
    Result.AddPair('description', Description);
  if MimeType <> '' then
    Result.AddPair('mimeType', MimeType);
end;

function CreateEmbeddedTextBlock(const Uri, MimeType, Text: string): TJSONObject;
begin
  var Resource := TJSONObject.Create;
  Resource.AddPair('uri', Uri);
  Resource.AddPair('mimeType', MimeType);
  Resource.AddPair('text', Text);
  Result := TJSONObject.Create;
  Result.AddPair('type', 'resource');
  Result.AddPair('resource', Resource);
end;

function CreateEmbeddedBlobBlock(const Uri, MimeType, Base64Blob: string): TJSONObject;
begin
  var Resource := TJSONObject.Create;
  Resource.AddPair('uri', Uri);
  Resource.AddPair('mimeType', MimeType);
  Resource.AddPair('blob', Base64Blob);
  Result := TJSONObject.Create;
  Result.AddPair('type', 'resource');
  Result.AddPair('resource', Resource);
end;

end.
