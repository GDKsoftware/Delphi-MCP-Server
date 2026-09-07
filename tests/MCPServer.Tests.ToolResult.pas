unit MCPServer.Tests.ToolResult;

interface

uses
  DUnitX.TestFramework;

type
  [TestFixture]
  TToolResultTests = class
  public
    [Test] procedure Text_ProducesOneTextBlock;
    [Test] procedure Image_Audio_Embedded_Blocks;
    [Test] procedure StructuredOnly_GetsTextFallback;
    [Test] procedure StructuredArray_LegacyDropsIt_ModernKeepsIt;
    [Test] procedure Error_SetsIsError;
    [Test] procedure Meta_IsEmitted;
    [Test] procedure Annotations_AttachToLastBlock;
    [Test] procedure Annotations_BeforeAnyBlock_AttachToTheNextBlock;
    [Test] procedure Base64Blob_HasNoLineBreaks;
  end;

implementation

uses
  System.SysUtils,
  System.JSON,
  MCPServer.Types,
  MCPServer.ContentBlocks,
  MCPServer.Tool.Result;

{ TToolResultTests }

procedure TToolResultTests.Text_ProducesOneTextBlock;
begin
  var ToolResult := TMCPToolResult.Text('hello');
  var Json := ToolResult.ToJson(TMCPProtocolEra.Legacy);
  try
    Assert.AreEqual('text', Json.GetValue<string>('content[0].type'));
    Assert.AreEqual('hello', Json.GetValue<string>('content[0].text'));
    Assert.IsNull(Json.GetValue('isError'));
    Assert.IsNull(Json.GetValue('structuredContent'));
  finally
    Json.Free;
    ToolResult.Free;
  end;
end;

procedure TToolResultTests.Image_Audio_Embedded_Blocks;
begin
  var ToolResult := TMCPToolResult.Create
    .AddImage(TEncoding.UTF8.GetBytes('png'), 'image/png')
    .AddAudio('AAAA', 'audio/wav')
    .AddEmbeddedText('test://x', 'text/plain', 'body')
    .AddEmbeddedBlob('test://y', 'application/octet-stream', TEncoding.UTF8.GetBytes('bin'))
    .AddResourceLink('file:///a.txt', 'a.txt', 'A file', 'text/plain');
  var Json := ToolResult.ToJson(TMCPProtocolEra.Modern);
  try
    Assert.AreEqual(5, (Json.GetValue('content') as TJSONArray).Count);
    Assert.AreEqual('image', Json.GetValue<string>('content[0].type'));
    Assert.AreEqual('cG5n', Json.GetValue<string>('content[0].data'));
    Assert.AreEqual('image/png', Json.GetValue<string>('content[0].mimeType'));
    Assert.AreEqual('audio', Json.GetValue<string>('content[1].type'));
    Assert.AreEqual('resource', Json.GetValue<string>('content[2].type'));
    Assert.AreEqual('body', Json.GetValue<string>('content[2].resource.text'));
    Assert.AreEqual('Ymlu', Json.GetValue<string>('content[3].resource.blob'));
    Assert.AreEqual('resource_link', Json.GetValue<string>('content[4].type'));
    Assert.AreEqual('A file', Json.GetValue<string>('content[4].description'));
  finally
    Json.Free;
    ToolResult.Free;
  end;
end;

procedure TToolResultTests.StructuredOnly_GetsTextFallback;
begin
  var ToolResult := TMCPToolResult.Create.SetStructuredContent(TJSONObject.ParseJSONValue('{"a":1}'));
  var Json := ToolResult.ToJson(TMCPProtocolEra.Legacy);
  try
    Assert.AreEqual('{"a":1}', Json.GetValue<string>('content[0].text'));
    Assert.AreEqual(1, Json.GetValue<Integer>('structuredContent.a'));
  finally
    Json.Free;
    ToolResult.Free;
  end;
end;

procedure TToolResultTests.StructuredArray_LegacyDropsIt_ModernKeepsIt;
begin
  var ToolResult := TMCPToolResult.Text('list').SetStructuredContent(TJSONObject.ParseJSONValue('[1,2]'));
  var Legacy := ToolResult.ToJson(TMCPProtocolEra.Legacy);
  var Modern := ToolResult.ToJson(TMCPProtocolEra.Modern);
  try
    Assert.IsNull(Legacy.GetValue('structuredContent'), 'legacy schemas only allow objects');
    Assert.IsTrue(Modern.GetValue('structuredContent') is TJSONArray);
  finally
    Legacy.Free;
    Modern.Free;
    ToolResult.Free;
  end;
end;

procedure TToolResultTests.Error_SetsIsError;
begin
  var ToolResult := TMCPToolResult.Error('boom');
  var Json := ToolResult.ToJson(TMCPProtocolEra.Modern);
  try
    Assert.IsTrue(Json.GetValue<Boolean>('isError'));
    Assert.AreEqual('boom', Json.GetValue<string>('content[0].text'));
  finally
    Json.Free;
    ToolResult.Free;
  end;
end;

procedure TToolResultTests.Meta_IsEmitted;
begin
  var Meta := TJSONObject.Create;
  Meta.AddPair('com.example/trace', 'abc');
  var ToolResult := TMCPToolResult.Text('x').SetMeta(Meta);
  var Json := ToolResult.ToJson(TMCPProtocolEra.Modern);
  try
    Assert.AreEqual('abc', Json.GetValue<string>('_meta["com.example/trace"]'));
  finally
    Json.Free;
    ToolResult.Free;
  end;
end;

procedure TToolResultTests.Annotations_BeforeAnyBlock_AttachToTheNextBlock;
begin
  var Annotations := TJSONObject.Create;
  Annotations.AddPair('priority', TJSONNumber.Create(0.5));
  var ToolResult := TMCPToolResult.Create.WithAnnotations(Annotations).AddText('first').AddText('second');
  var Json := ToolResult.ToJson(TMCPProtocolEra.Modern);
  try
    Assert.AreEqual(0.5, Json.GetValue<Double>('content[0].annotations.priority'), 0.0001);
    Assert.IsNull(Json.FindValue('content[1].annotations'));
  finally
    Json.Free;
    ToolResult.Free;
  end;
end;

procedure TToolResultTests.Annotations_AttachToLastBlock;
begin
  var Annotations := TJSONObject.Create;
  Annotations.AddPair('priority', TJSONNumber.Create(0.5));
  var ToolResult := TMCPToolResult.Text('first').AddText('second').WithAnnotations(Annotations);
  var Json := ToolResult.ToJson(TMCPProtocolEra.Modern);
  try
    Assert.IsNull(Json.FindValue('content[0].annotations'));
    Assert.AreEqual(0.5, Json.GetValue<Double>('content[1].annotations.priority'), 0.0001);
  finally
    Json.Free;
    ToolResult.Free;
  end;
end;

procedure TToolResultTests.Base64Blob_HasNoLineBreaks;
begin
  var Bytes: TBytes;
  SetLength(Bytes, 300);
  for var I := 0 to High(Bytes) do
    Bytes[I] := Byte(I);
  var Encoded := TMCPContentBlock.EncodeBlob(Bytes);
  Assert.AreEqual(400, Length(Encoded));
  Assert.IsFalse(Encoded.Contains(#13) or Encoded.Contains(#10));
end;

end.
