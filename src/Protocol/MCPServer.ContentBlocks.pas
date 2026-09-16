unit MCPServer.ContentBlocks;

interface

uses
  System.SysUtils,
  System.JSON,
  MCPServer.Types;

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

const
  BLOCK_TYPE_RESOURCE = 'resource';
  KEY_DATA = 'data';


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
  Result.AddPair(MCP_KEY_TYPE, 'text');
  Result.AddPair(MCP_KEY_TEXT, Value);
end;

class function TMCPContentBlock.Image(const Base64Data, MimeType: string): TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair(MCP_KEY_TYPE, 'image');
  Result.AddPair(KEY_DATA, Base64Data);
  Result.AddPair(MCP_KEY_MIME_TYPE, MimeType);
end;

class function TMCPContentBlock.Audio(const Base64Data, MimeType: string): TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair(MCP_KEY_TYPE, 'audio');
  Result.AddPair(KEY_DATA, Base64Data);
  Result.AddPair(MCP_KEY_MIME_TYPE, MimeType);
end;

class function TMCPContentBlock.ResourceLink(const Uri, Name, Description, MimeType: string): TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair(MCP_KEY_TYPE, 'resource_link');
  Result.AddPair(MCP_KEY_URI, Uri);
  Result.AddPair(MCP_KEY_NAME, Name);
  const HasDescription = (Description <> '');
  if HasDescription then
    Result.AddPair(MCP_KEY_DESCRIPTION, Description);
  const HasMimeType = (MimeType <> '');
  if HasMimeType then
    Result.AddPair(MCP_KEY_MIME_TYPE, MimeType);
end;

class function TMCPContentBlock.EmbeddedText(const Uri, MimeType, Text: string): TJSONObject;
begin
  var Resource := TJSONObject.Create;
  Resource.AddPair(MCP_KEY_URI, Uri);
  Resource.AddPair(MCP_KEY_MIME_TYPE, MimeType);
  Resource.AddPair(MCP_KEY_TEXT, Text);
  Result := TJSONObject.Create;
  Result.AddPair(MCP_KEY_TYPE, BLOCK_TYPE_RESOURCE);
  Result.AddPair(BLOCK_TYPE_RESOURCE, Resource);
end;

class function TMCPContentBlock.EmbeddedBlob(const Uri, MimeType, Base64Blob: string): TJSONObject;
begin
  var Resource := TJSONObject.Create;
  Resource.AddPair(MCP_KEY_URI, Uri);
  Resource.AddPair(MCP_KEY_MIME_TYPE, MimeType);
  Resource.AddPair('blob', Base64Blob);
  Result := TJSONObject.Create;
  Result.AddPair(MCP_KEY_TYPE, BLOCK_TYPE_RESOURCE);
  Result.AddPair(BLOCK_TYPE_RESOURCE, Resource);
end;

end.
