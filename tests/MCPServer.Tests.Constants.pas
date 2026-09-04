unit MCPServer.Tests.Constants;

interface

uses
  DUnitX.TestFramework;

type
  [TestFixture]
  TProtocolConstantsTests = class
  public
    [Test] procedure JsonRpcErrorCodes_HaveSpecValues;
    [Test] procedure ProcessorAliases_MatchTypes;
    [Test] procedure McpErrorCodes_HaveSpecValues;
    [Test] procedure ProtocolVersions_AreConsistent;
    [Test] procedure MetaKeys_UseReservedPrefix;
    [Test] procedure CacheableMethods_MatchSpec;
    [Test] procedure IsJsonString_AcceptsStringsOnly;
  end;

implementation

uses
  System.SysUtils,
  System.JSON,
  MCPServer.Types,
  MCPServer.JsonRpcProcessor;

{ TProtocolConstantsTests }

procedure TProtocolConstantsTests.JsonRpcErrorCodes_HaveSpecValues;
begin
  Assert.AreEqual(-32700, MCPServer.Types.JSONRPC_PARSE_ERROR);
  Assert.AreEqual(-32600, MCPServer.Types.JSONRPC_INVALID_REQUEST);
  Assert.AreEqual(-32601, MCPServer.Types.JSONRPC_METHOD_NOT_FOUND);
  Assert.AreEqual(-32602, MCPServer.Types.JSONRPC_INVALID_PARAMS);
  Assert.AreEqual(-32603, MCPServer.Types.JSONRPC_INTERNAL_ERROR);
end;

procedure TProtocolConstantsTests.ProcessorAliases_MatchTypes;
begin
  Assert.AreEqual(MCPServer.Types.JSONRPC_PARSE_ERROR, MCPServer.JsonRpcProcessor.JSONRPC_PARSE_ERROR);
  Assert.AreEqual(MCPServer.Types.JSONRPC_INVALID_REQUEST, MCPServer.JsonRpcProcessor.JSONRPC_INVALID_REQUEST);
  Assert.AreEqual(MCPServer.Types.JSONRPC_METHOD_NOT_FOUND, MCPServer.JsonRpcProcessor.JSONRPC_METHOD_NOT_FOUND);
  Assert.AreEqual(MCPServer.Types.JSONRPC_INVALID_PARAMS, MCPServer.JsonRpcProcessor.JSONRPC_INVALID_PARAMS);
  Assert.AreEqual(MCPServer.Types.JSONRPC_INTERNAL_ERROR, MCPServer.JsonRpcProcessor.JSONRPC_INTERNAL_ERROR);
end;

procedure TProtocolConstantsTests.McpErrorCodes_HaveSpecValues;
begin
  Assert.AreEqual(-32020, MCP_ERROR_HEADER_MISMATCH);
  Assert.AreEqual(-32021, MCP_ERROR_MISSING_REQUIRED_CLIENT_CAPABILITY);
  Assert.AreEqual(-32022, MCP_ERROR_UNSUPPORTED_PROTOCOL_VERSION);
  Assert.AreEqual(-32002, MCP_ERROR_RESOURCE_NOT_FOUND_LEGACY);
end;

procedure TProtocolConstantsTests.ProtocolVersions_AreConsistent;
begin
  Assert.AreEqual('2025-06-18', MCP_PROTOCOL_VERSION, 'the initialize handshake answers this revision');
  Assert.AreEqual('2026-07-28', MCP_LATEST_PROTOCOL_VERSION);
  Assert.AreEqual('2025-11-25', MCP_LATEST_LEGACY_PROTOCOL_VERSION);

  Assert.AreEqual(2, Length(MCP_LEGACY_PROTOCOL_VERSIONS));
  Assert.AreEqual(MCP_PROTOCOL_VERSION_2025_11_25, MCP_LEGACY_PROTOCOL_VERSIONS[0]);
  Assert.AreEqual(MCP_PROTOCOL_VERSION_2025_06_18, MCP_LEGACY_PROTOCOL_VERSIONS[1]);

  Assert.AreEqual(1, Length(MCP_MODERN_PROTOCOL_VERSIONS));
  Assert.AreEqual(MCP_LATEST_PROTOCOL_VERSION, MCP_MODERN_PROTOCOL_VERSIONS[0]);
end;

procedure TProtocolConstantsTests.MetaKeys_UseReservedPrefix;
const
  RESERVED_PREFIX = 'io.modelcontextprotocol/';
begin
  Assert.IsTrue(MCP_META_PROTOCOL_VERSION.StartsWith(RESERVED_PREFIX));
  Assert.IsTrue(MCP_META_CLIENT_CAPABILITIES.StartsWith(RESERVED_PREFIX));
  Assert.IsTrue(MCP_META_CLIENT_INFO.StartsWith(RESERVED_PREFIX));
  Assert.IsTrue(MCP_META_LOG_LEVEL.StartsWith(RESERVED_PREFIX));
  Assert.IsTrue(MCP_META_SERVER_INFO.StartsWith(RESERVED_PREFIX));
  Assert.IsTrue(MCP_META_SUBSCRIPTION_ID.StartsWith(RESERVED_PREFIX));
  Assert.AreEqual('progressToken', MCP_META_PROGRESS_TOKEN);
end;

procedure TProtocolConstantsTests.CacheableMethods_MatchSpec;
begin
  Assert.AreEqual(6, Length(MCP_CACHEABLE_METHODS));
  Assert.AreEqual('server/discover', MCP_CACHEABLE_METHODS[0]);
  Assert.AreEqual('tools/list', MCP_CACHEABLE_METHODS[1]);
  Assert.AreEqual('prompts/list', MCP_CACHEABLE_METHODS[2]);
  Assert.AreEqual('resources/list', MCP_CACHEABLE_METHODS[3]);
  Assert.AreEqual('resources/templates/list', MCP_CACHEABLE_METHODS[4]);
  Assert.AreEqual('resources/read', MCP_CACHEABLE_METHODS[5]);
end;

procedure TProtocolConstantsTests.IsJsonString_AcceptsStringsOnly;
begin
  var Json := TJSONObject.ParseJSONValue('{"s":"text","n":12345,"f":1.5,"b":true,"o":{},"z":null}') as TJSONObject;
  try
    Assert.IsTrue(IsJsonString(Json.GetValue('s')));
    Assert.IsFalse(IsJsonString(Json.GetValue('n')), 'a number is not a string');
    Assert.IsFalse(IsJsonString(Json.GetValue('f')));
    Assert.IsFalse(IsJsonString(Json.GetValue('b')));
    Assert.IsFalse(IsJsonString(Json.GetValue('o')));
    Assert.IsFalse(IsJsonString(Json.GetValue('z')));
    Assert.IsFalse(IsJsonString(nil));
  finally
    Json.Free;
  end;
end;

end.
