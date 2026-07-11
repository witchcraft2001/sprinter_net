#!/usr/bin/env perl
use strict;
use warnings;
use IO::Pty;
use File::Temp qw(tempdir tempfile);
use POSIX qw(_exit);

my $lsb = $ENV{LSB} || 'lsb';
my $lrb = $ENV{LRB} || 'lrb';

sub crc16 {
    my ($data) = @_;
    my $crc = 0;
    for my $byte (unpack('C*', $data)) {
        $crc ^= $byte << 8;
        for (1 .. 8) {
            $crc = ($crc & 0x8000) ? (($crc << 1) ^ 0x1021) & 0xffff
                                    : ($crc << 1) & 0xffff;
        }
    }
    return $crc;
}

sub packet {
    my ($start, $block, $data, $size) = @_;
    $data .= "\0" x ($size - length($data));
    die "oversized Ymodem packet" if length($data) != $size;
    return pack('CCC', $start, $block, 0xff ^ $block)
         . $data . pack('n', crc16($data));
}

sub spawn_pty {
    my ($cwd, @command) = @_;
    my $pty = IO::Pty->new;
    my $slave = $pty->slave;
    # Let lsb/lrb configure the slave itself, matching an interactive login PTY.
    my $pid = fork();
    die "fork: $!" unless defined $pid;
    if (!$pid) {
        chdir $cwd or _exit(126);
		$pty->make_slave_controlling_terminal;
		$pty->close;
        open STDIN,  '<&', $slave or _exit(126);
        open STDOUT, '>&', $slave or _exit(126);
        open STDERR, '>', '/dev/null' or _exit(126);
		exec { $command[0] } @command or _exit(127);
    }
	$pty->close_slave;
    $pty->set_raw;
    return ($pid, $pty);
}

sub read_exact {
    my ($fh, $length) = @_;
    my $data = '';
    local $SIG{ALRM} = sub { die "Ymodem timeout\n" };
    alarm 10;
    while (length($data) < $length) {
        my $count = sysread($fh, my $part, $length - length($data));
        die "Ymodem EOF\n" unless $count;
        $data .= $part;
    }
    alarm 0;
    return $data;
}

sub write_all {
    my ($fh, $data) = @_;
    while (length $data) {
        my $count = syswrite($fh, $data);
        die "Ymodem write: $!" unless $count;
        substr($data, 0, $count, '');
    }
}

sub check_packet {
    my ($wire, $start, $block, $size) = @_;
    die "bad packet size" unless length($wire) == $size + 5;
    my ($got_start, $got_block, $inverse) = unpack('CCC', substr($wire, 0, 3));
    die "bad packet header" unless $got_start == $start
        && $got_block == $block && (($got_block ^ $inverse) == 0xff);
    my $data = substr($wire, 3, $size);
    my $got_crc = unpack('n', substr($wire, 3 + $size, 2));
    die "bad packet CRC" unless $got_crc == crc16($data);
    return $data;
}

sub test_lsb {
    my $dir = tempdir(CLEANUP => 1);
    open my $file, '>:raw', "$dir/sample.bin" or die $!;
    print {$file} "TEST";
    close $file;
    my ($pid, $pty) = spawn_pty($dir, $lsb, '--ymodem', '-q', 'sample.bin');
    write_all($pty, 'C');
    my $meta = check_packet(read_exact($pty, 133), 0x01, 0, 128);
    die "lsb filename" unless $meta =~ /^sample\.bin\0/;
    write_all($pty, "\x06C");
    my $data = check_packet(read_exact($pty, 133), 0x01, 1, 128);
    die "lsb payload" unless substr($data, 0, 4) eq 'TEST';
    write_all($pty, "\x06");
    die "lsb EOT" unless read_exact($pty, 1) eq "\x04";
    write_all($pty, "\x06C");
    my $last = check_packet(read_exact($pty, 133), 0x01, 0, 128);
    die "lsb final block" unless substr($last, 0, 1) eq "\0";
    write_all($pty, "\x06");
    waitpid($pid, 0);
    die "lsb failed" if $?;
}

sub test_lsb_g {
    my $dir = tempdir(CLEANUP => 1);
    open my $file, '>:raw', "$dir/sample-g.bin" or die $!;
    print {$file} "GDATA";
    close $file;
    my ($pid, $pty) = spawn_pty($dir, $lsb, '--ymodem', '-q', 'sample-g.bin');
    write_all($pty, 'G');
    my $meta = check_packet(read_exact($pty, 133), 0x01, 0, 128);
    die "lsb-g filename" unless $meta =~ /^sample-g\.bin\0/;
    write_all($pty, 'G');
    my $data = check_packet(read_exact($pty, 133), 0x01, 1, 128);
    die "lsb-g payload" unless substr($data, 0, 5) eq 'GDATA';
    die "lsb-g EOT" unless read_exact($pty, 1) eq "\x04";
    write_all($pty, "\x06G");
    my $last = check_packet(read_exact($pty, 133), 0x01, 0, 128);
    die "lsb-g final block" unless substr($last, 0, 1) eq "\0";
    write_all($pty, "\x06");
    waitpid($pid, 0);
    die "lsb-g failed" if $?;
}

sub test_lrb {
    my $dir = tempdir(CLEANUP => 1);
    my $source = join('', map { chr(($_ * 73 + ($_ >> 8)) & 0xff) } 0 .. 390 * 1024 - 1);
    my ($pid, $pty) = spawn_pty($dir, $lrb, '--ymodem', '-q', '-y');
    die "lrb CRC request" unless read_exact($pty, 1) eq 'C';
    write_all($pty, packet(0x01, 0, "upload.bin\0" . length($source) . " 0 0 0", 128));
    die "lrb block-0 ACK/C" unless read_exact($pty, 2) eq "\x06C";
    my $block = 1;
    while (length $source) {
        my $part = substr($source, 0, 1024, '');
        $part .= "\x1a" x (1024 - length($part));
        write_all($pty, packet(0x02, $block, $part, 1024));
        die "lrb data ACK at block $block" unless read_exact($pty, 1) eq "\x06";
        $block = ($block + 1) & 0xff;
    }
    write_all($pty, "\x04");
    die "lrb EOT ACK/C" unless read_exact($pty, 2) eq "\x06C";
    write_all($pty, packet(0x01, 0, '', 128));
    die "lrb final ACK" unless read_exact($pty, 1) eq "\x06";
    waitpid($pid, 0);
    die "lrb failed" if $?;
    open my $file, '<:raw', "$dir/upload.bin" or die $!;
    local $/;
    my $data = <$file>;
    close $file;
    my $expected = join('', map { chr(($_ * 73 + ($_ >> 8)) & 0xff) } 0 .. 390 * 1024 - 1);
    die "lrb output mismatch" unless $data eq $expected;
}

test_lsb();
test_lsb_g();
test_lrb();
print "Ymodem/Ymodem-G lsb/lrb interoperability: OK\n";
