program StdioOnlyHost;

{$APPTYPE CONSOLE}

uses
  StdioOnlyHost.Check in 'StdioOnlyHost.Check.pas';

begin
  ExitCode := TStdioOnlyHostCheck.Run;
end.
