{ ================================================================== }
{ UNETDEMO.PAS - Turbo Pascal (DSS TPC) consumer of the UNET DLL.     }
{                                                                     }
{ Build:  TPC /D:8000 /L:LIB UNETDEMO.PAS                             }
{   /D:8000 keeps this program below window 2 so the DLL can be       }
{   loaded into window 2 (UNetLoad('UNETESP.DLL', 2)).                }
{                                                                     }
{ Run:    NETUP  then  UNETDEMO  (UNETESP.DLL in the same directory). }
{ ================================================================== }
program UnetDemo;
{$I DSSCORE.INC}
{$I DSSFILE.INC}
{$I DSSSYS.INC}
{$I LIBMAN.INC}
{$I UNETPAS.INC}

const
  HostName = 'example.com';
  PortName = '80';

var
  st   : byte;
  caps : integer;
  bits : integer;
  ms   : integer;
  n    : integer;
  ip   : DssStr;

begin
  writeln('UNETDEMO - UNET DLL via Turbo Pascal');

  if not UNetLoad('UNETESP.DLL', 2) then
  begin
    writeln('load failed, LibErr=', LibErr);
    exit
  end;
  writeln('loaded "', LibName(UNetHandle), '"');

  caps := UNetCaps;
  writeln('caps = ', caps);

  st := UNetNetStatus(bits);
  writeln('net status = ', st, ' (bits ', bits, ')');

  st := UNetInit;
  if st <> NErrOk then
  begin
    writeln('NETINIT failed: ', st);
    writeln('lasterr: ', UNetLastErr);
    UNetUnload;
    exit
  end;

  writeln('IP: ', UNetGetInfo(UNetIfIp));

  ms := UNetPing(HostName, 3000);
  if ms >= 0 then writeln('ping: ', ms, ' ms')
  else            writeln('ping failed: ', -ms);

  st := UNetConnect(HostName, PortName);
  if st <> NErrOk then
  begin
    writeln('connect failed: ', st);
    UNetUnload;
    exit
  end;

  n := UNetSend('HEAD / HTTP/1.0' + chr(13) + chr(10) +
                'Host: ' + HostName + chr(13) + chr(10) +
                'Connection: close' + chr(13) + chr(10) + chr(13) + chr(10));
  writeln('sent ', n, ' bytes');

  writeln('--- reply ---');
  repeat
    n := UNetRecv(4000);
    if n > 0 then write(UNetRecvStr);
  until n <= 0;
  writeln;
  writeln('--- done ---');

  st := UNetClose;
  st := UNetDone;
  UNetUnload
end.
