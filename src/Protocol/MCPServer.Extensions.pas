unit MCPServer.Extensions;

interface

uses
  System.JSON,
  MCPServer.Types;

type
  TMCPExtensions = record
  private
    class function Providers(const Registry: IMCPManagerRegistry): TArray<IMCPExtensionProvider>; static;
    class procedure CheckExtensionId(const ExtensionId: string; const Extensions: TJSONObject); static;
  public
    class function IsValidId(const ExtensionId: string): Boolean; static;
    class function Describe(const Registry: IMCPManagerRegistry): TJSONObject; static;
    class function TryFindByResultType(const Registry: IMCPManagerRegistry; const ResultType: string;
      out Provider: IMCPExtensionProvider): Boolean; static;
  end;

implementation

uses
  System.SysUtils,
  System.RegularExpressions,
  MCPServer.Errors;

const
  EXTENSION_ID_PATTERN =
    '^[A-Za-z](?:[A-Za-z0-9-]*[A-Za-z0-9])?(?:\.[A-Za-z](?:[A-Za-z0-9-]*[A-Za-z0-9])?)*' +
    '/[A-Za-z0-9](?:[A-Za-z0-9._-]*[A-Za-z0-9])?$';
  MESSAGE_INVALID_EXTENSION_ID = 'Extension id ''%s'' is not a valid {vendor-prefix}/{extension-name} identifier';
  MESSAGE_DUPLICATE_EXTENSION_ID = 'Extension id ''%s'' is provided more than once';

{ TMCPExtensions }

class function TMCPExtensions.Describe(const Registry: IMCPManagerRegistry): TJSONObject;
begin
  const ExtensionProviders = Providers(Registry);
  const HasProviders = (Length(ExtensionProviders) > 0);
  if not HasProviders then
    Exit(nil);

  Result := TJSONObject.Create;
  try
    for var Provider in ExtensionProviders do
    begin
      const ExtensionId = Provider.ExtensionId;
      CheckExtensionId(ExtensionId, Result);
      const Settings = Provider.GetExtensionSettings;
      Result.AddPair(ExtensionId, Settings);
    end;
  except
    Result.Free;
    raise;
  end;
end;

class function TMCPExtensions.TryFindByResultType(const Registry: IMCPManagerRegistry; const ResultType: string;
  out Provider: IMCPExtensionProvider): Boolean;
begin
  for var Candidate in Providers(Registry) do
  begin
    for var OwnedResultType in Candidate.ResultTypes do
    begin
      const IsOwned = (OwnedResultType = ResultType);
      if IsOwned then
      begin
        Provider := Candidate;
        Exit(True);
      end;
    end;
  end;

  Provider := nil;
  Result := False;
end;

class function TMCPExtensions.Providers(const Registry: IMCPManagerRegistry): TArray<IMCPExtensionProvider>;
begin
  Result := nil;
  var Enumerator: IMCPManagerEnumerator;
  if not Supports(Registry, IMCPManagerEnumerator, Enumerator) then
    Exit;

  for var Manager in Enumerator.GetManagers do
  begin
    var Provider: IMCPExtensionProvider;
    if Supports(Manager, IMCPExtensionProvider, Provider) then
      Result := Result + [Provider];
  end;
end;

class procedure TMCPExtensions.CheckExtensionId(const ExtensionId: string; const Extensions: TJSONObject);
begin
  if not IsValidId(ExtensionId) then
    raise EMCPConfigurationError.CreateFmt(MESSAGE_INVALID_EXTENSION_ID, [ExtensionId]);

  const IsDuplicate = Assigned(Extensions.GetValue(ExtensionId));
  if IsDuplicate then
    raise EMCPConfigurationError.CreateFmt(MESSAGE_DUPLICATE_EXTENSION_ID, [ExtensionId]);
end;

class function TMCPExtensions.IsValidId(const ExtensionId: string): Boolean;
begin
  Result := TRegEx.IsMatch(ExtensionId, EXTENSION_ID_PATTERN);
end;

end.
