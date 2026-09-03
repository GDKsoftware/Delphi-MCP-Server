unit MCPServer.Prompt.Base;

interface

uses
  System.SysUtils,
  System.Rtti,
  System.JSON,
  MCPServer.Types,
  MCPServer.Resource.Base;

type
  TMCPPromptArgument = record
    Name: string;
    Description: string;
    Required: Boolean;
  end;

  /// Builds the messages of a prompts/get result: one role plus one content
  /// block per message, the same block shapes tools/call uses (text, image,
  /// audio, resource_link, embedded resource).
  TMCPPromptMessages = class
  strict private
    FMessages: TJSONArray;
    function AddMessage(const Role: string; const Content: TJSONObject): TMCPPromptMessages;
  public
    constructor Create;
    destructor Destroy; override;

    function AddText(const Role, Text: string): TMCPPromptMessages;
    /// Data is the raw content; it is Base64-encoded here.
    function AddImage(const Role: string; const Data: TBytes; const MimeType: string): TMCPPromptMessages; overload;
    function AddImage(const Role, Base64Data, MimeType: string): TMCPPromptMessages; overload;
    function AddAudio(const Role: string; const Data: TBytes; const MimeType: string): TMCPPromptMessages; overload;
    function AddAudio(const Role, Base64Data, MimeType: string): TMCPPromptMessages; overload;
    function AddResourceLink(const Role, Uri, Name: string; const Description: string = '';
      const MimeType: string = ''): TMCPPromptMessages;
    function AddEmbeddedText(const Role, Uri, MimeType, Text: string): TMCPPromptMessages;
    function AddEmbeddedBlob(const Role, Uri, MimeType: string; const Data: TBytes): TMCPPromptMessages;
    /// Reads Resource (text, or blob for an IMCPBinaryResource) and embeds
    /// it under Role.
    function AddEmbeddedResource(const Role: string; const Resource: IMCPResource): TMCPPromptMessages;
    /// Annotations for the message added last (audience, priority, lastModified).
    function WithAnnotations(const Annotations: TJSONObject): TMCPPromptMessages;

    /// The messages array for the result; the caller owns the clone.
    function ToJson: TJSONArray;
  end;

  IMCPPrompt = interface
    ['{6B8DFAF4-D0E3-4A56-8637-8DFAF4D0E3A5}']
    function GetName: string;
    function GetTitle: string;
    function GetDescription: string;
    function GetArguments: TArray<TMCPPromptArgument>;
    /// Arguments is never nil (an empty object when the request omitted
    /// it). Builds the messages into Messages; returns the optional
    /// result-level description.
    function Get(const Arguments: TJSONObject; Messages: TMCPPromptMessages): string;

    property Name: string read GetName;
    property Title: string read GetTitle;
    property Description: string read GetDescription;
    property Arguments: TArray<TMCPPromptArgument> read GetArguments;
  end;

  /// Prompt with a hand-written argument list and raw JSON arguments.
  TMCPPromptBase = class(TInterfacedObject, IMCPPrompt, IMCPPromptMetadata)
  protected
    FName: string;
    FTitle: string;
    FDescription: string;
    FArguments: TArray<TMCPPromptArgument>;
    FIcons: TJSONArray;
  public
    constructor Create; virtual;
    destructor Destroy; override;

    function GetName: string;
    function GetTitle: string;
    function GetDescription: string;
    function GetArguments: TArray<TMCPPromptArgument>;
    function GetIcons: TJSONArray;
    function Get(const Arguments: TJSONObject; Messages: TMCPPromptMessages): string; virtual; abstract;
  end;

  /// Prompt whose arguments are the string properties of a class T; the
  /// argument list comes from T's RTTI, [SchemaDescription] and [Optional]
  /// (a required property that is missing from arguments is -32602).
  ///
  /// T must declare only string properties: prompts/get arguments are
  /// always plain strings on the wire.
  TMCPPromptBase<T: class, constructor> = class(TInterfacedObject, IMCPPrompt, IMCPPromptMetadata)
  protected
    FName: string;
    FTitle: string;
    FDescription: string;
    FIcons: TJSONArray;
    function ExecuteWithParams(const Params: T; Messages: TMCPPromptMessages): string; virtual; abstract;
  public
    constructor Create; virtual;
    destructor Destroy; override;

    function GetName: string;
    function GetTitle: string;
    function GetDescription: string;
    function GetArguments: TArray<TMCPPromptArgument>;
    function GetIcons: TJSONArray;
    function Get(const Arguments: TJSONObject; Messages: TMCPPromptMessages): string;
  end;

implementation

uses
  System.Classes,
  System.Generics.Collections,
  MCPServer.ContentBlocks,
  MCPServer.Serializer;

{ TMCPPromptMessages }

constructor TMCPPromptMessages.Create;
begin
  inherited Create;
  FMessages := TJSONArray.Create;
end;

destructor TMCPPromptMessages.Destroy;
begin
  FMessages.Free;
  inherited;
end;

function TMCPPromptMessages.AddMessage(const Role: string; const Content: TJSONObject): TMCPPromptMessages;
begin
  var Message := TJSONObject.Create;
  Message.AddPair('role', Role);
  Message.AddPair('content', Content);
  FMessages.AddElement(Message);
  Result := Self;
end;

function TMCPPromptMessages.AddText(const Role, Text: string): TMCPPromptMessages;
begin
  Result := AddMessage(Role, CreateTextBlock(Text));
end;

function TMCPPromptMessages.AddImage(const Role: string; const Data: TBytes;
  const MimeType: string): TMCPPromptMessages;
begin
  Result := AddImage(Role, EncodeBase64Blob(Data), MimeType);
end;

function TMCPPromptMessages.AddImage(const Role, Base64Data, MimeType: string): TMCPPromptMessages;
begin
  Result := AddMessage(Role, CreateImageBlock(Base64Data, MimeType));
end;

function TMCPPromptMessages.AddAudio(const Role: string; const Data: TBytes;
  const MimeType: string): TMCPPromptMessages;
begin
  Result := AddAudio(Role, EncodeBase64Blob(Data), MimeType);
end;

function TMCPPromptMessages.AddAudio(const Role, Base64Data, MimeType: string): TMCPPromptMessages;
begin
  Result := AddMessage(Role, CreateAudioBlock(Base64Data, MimeType));
end;

function TMCPPromptMessages.AddResourceLink(const Role, Uri, Name, Description,
  MimeType: string): TMCPPromptMessages;
begin
  Result := AddMessage(Role, CreateResourceLinkBlock(Uri, Name, Description, MimeType));
end;

function TMCPPromptMessages.AddEmbeddedText(const Role, Uri, MimeType, Text: string): TMCPPromptMessages;
begin
  Result := AddMessage(Role, CreateEmbeddedTextBlock(Uri, MimeType, Text));
end;

function TMCPPromptMessages.AddEmbeddedBlob(const Role, Uri, MimeType: string;
  const Data: TBytes): TMCPPromptMessages;
begin
  Result := AddMessage(Role, CreateEmbeddedBlobBlock(Uri, MimeType, EncodeBase64Blob(Data)));
end;

function TMCPPromptMessages.AddEmbeddedResource(const Role: string; const Resource: IMCPResource): TMCPPromptMessages;
var
  Binary: IMCPBinaryResource;
begin
  if Supports(Resource, IMCPBinaryResource, Binary) then
    Result := AddEmbeddedBlob(Role, Resource.URI, Resource.MimeType, Binary.ReadBinary)
  else
    Result := AddEmbeddedText(Role, Resource.URI, Resource.MimeType, Resource.Read);
end;

function TMCPPromptMessages.WithAnnotations(const Annotations: TJSONObject): TMCPPromptMessages;
begin
  if FMessages.Count = 0 then
  begin
    Annotations.Free;
    raise EInvalidOperation.Create('WithAnnotations needs a message to attach to');
  end;
  var LastMessage := TJSONObject(FMessages.Items[FMessages.Count - 1]);
  TJSONObject(LastMessage.GetValue('content')).AddPair('annotations', Annotations);
  Result := Self;
end;

function TMCPPromptMessages.ToJson: TJSONArray;
begin
  Result := TJSONArray(FMessages.Clone);
end;

{ TMCPPromptBase }

constructor TMCPPromptBase.Create;
begin
  inherited Create;
end;

destructor TMCPPromptBase.Destroy;
begin
  FIcons.Free;
  inherited;
end;

function TMCPPromptBase.GetName: string;
begin
  Result := FName;
end;

function TMCPPromptBase.GetTitle: string;
begin
  if FTitle <> '' then
    Result := FTitle
  else
    Result := FName;
end;

function TMCPPromptBase.GetDescription: string;
begin
  Result := FDescription;
end;

function TMCPPromptBase.GetArguments: TArray<TMCPPromptArgument>;
begin
  Result := FArguments;
end;

function TMCPPromptBase.GetIcons: TJSONArray;
begin
  Result := FIcons;
end;

{ TMCPPromptBase<T> }

constructor TMCPPromptBase<T>.Create;
begin
  inherited Create;
end;

destructor TMCPPromptBase<T>.Destroy;
begin
  FIcons.Free;
  inherited;
end;

function TMCPPromptBase<T>.GetName: string;
begin
  Result := FName;
end;

function TMCPPromptBase<T>.GetTitle: string;
begin
  if FTitle <> '' then
    Result := FTitle
  else
    Result := FName;
end;

function TMCPPromptBase<T>.GetDescription: string;
begin
  Result := FDescription;
end;

function TMCPPromptBase<T>.GetIcons: TJSONArray;
begin
  Result := FIcons;
end;

function TMCPPromptBase<T>.GetArguments: TArray<TMCPPromptArgument>;
begin
  var Ctx := TRttiContext.Create;
  try
    var List := TList<TMCPPromptArgument>.Create;
    try
      for var Prop in Ctx.GetType(T).GetProperties do
      begin
        if not (Prop.IsReadable and Prop.IsWritable) then
          Continue;

        var Arg: TMCPPromptArgument;
        Arg.Name := LowerCase(Prop.Name);
        Arg.Description := '';
        Arg.Required := True;
        for var Attr in Prop.GetAttributes do
        begin
          if Attr is OptionalAttribute then
            Arg.Required := False
          else if Attr is SchemaDescriptionAttribute then
            Arg.Description := SchemaDescriptionAttribute(Attr).Description;
        end;
        List.Add(Arg);
      end;
      Result := List.ToArray;
    finally
      List.Free;
    end;
  finally
    Ctx.Free;
  end;
end;

function TMCPPromptBase<T>.Get(const Arguments: TJSONObject; Messages: TMCPPromptMessages): string;
var
  ParamsInstance: T;
begin
  ParamsInstance := TMCPSerializer.Deserialize<T>(Arguments);
  try
    Result := ExecuteWithParams(ParamsInstance, Messages);
  finally
    ParamsInstance.Free;
  end;
end;

end.
