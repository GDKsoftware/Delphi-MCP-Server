unit MCPServer.ContentBlocks;

interface

uses
  System.SysUtils,
  System.JSON;

type
  TMCPContentBlock = record
    class function Text(const Value: string): TJSONObject; static;
    class function Image(const Base64Data, MimeType: string): TJSONObject; static;
    class function Audio(const Base64Data, MimeType: string): TJSONObject; static;
    class function ResourceLink(const Uri, Name: string; const Description: string = '';
      const MimeType: string = ''): TJSONObject; static;
    class function EmbeddedText(const Uri, MimeType, Text: string): TJSONObject; static;
    class function EmbeddedBlob(const Uri, MimeType, Base64Blob: string): TJSONObject; static;
    class function EncodeBlob(const Data: TBytes): string; static;
  end;

implementation

uses
  System.NetEncoding;

{ TMCPContentBlock }

class function TMCPContentBlock.EncodeBlob(const Data: TBytes): string;
begin
  var Encoding := TBase64Encoding.Create(0);
  try
    Result := Encoding.EncodeBytesToString(Data);
  finally
    Encoding.Free;
  end;
end;

class function TMCPContentBlock.Text(const Value: string): TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('type', 'text');
  Result.AddPair('text', Value);
end;

class function TMCPContentBlock.Image(const Base64Data, MimeType: string): TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('type', 'image');
  Result.AddPair('data', Base64Data);
  Result.AddPair('mimeType', MimeType);
end;

class function TMCPContentBlock.Audio(const Base64Data, MimeType: string): TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('type', 'audio');
  Result.AddPair('data', Base64Data);
  Result.AddPair('mimeType', MimeType);
end;

class function TMCPContentBlock.ResourceLink(const Uri, Name, Description, MimeType: string): TJSONObject;
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

class function TMCPContentBlock.EmbeddedText(const Uri, MimeType, Text: string): TJSONObject;
begin
  var Resource := TJSONObject.Create;
  Resource.AddPair('uri', Uri);
  Resource.AddPair('mimeType', MimeType);
  Resource.AddPair('text', Text);
  Result := TJSONObject.Create;
  Result.AddPair('type', 'resource');
  Result.AddPair('resource', Resource);
end;

class function TMCPContentBlock.EmbeddedBlob(const Uri, MimeType, Base64Blob: string): TJSONObject;
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
