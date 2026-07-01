#!/usr/bin/perl
# c60-mark-slot-success.pl
#
# Mark the NXP iMX8MM boot_control_struct slot A as successfully booted so
# u-boot does NOT decrement tries_remaining on every reboot and eventually
# fall back to stock slot B.
#
# Layout:
#   misc bytes 0x800..0x81f:
#     +0x00..03  slot_suffix "\0AB0" magic
#     +0x04..07  version (LE u32 = 1)
#     +0x08..0b  slot A { priority, tries_remaining, successful_boot, reserved }
#     +0x0c..0f  slot B same
#     +0x10..1b  reserved (12 bytes zero)
#     +0x1c..1f  CRC32 BIG-ENDIAN over bytes 0x00..0x1b
#
# Action: set byte 0x09 (tries_remaining) = 0, 0x0a (successful_boot) = 1,
# recompute CRC32, write back in place. Idempotent.
#
# Only operates on slot A. If we're not running on slot A (per
# /proc/cmdline androidboot.slot_suffix), we exit successfully without
# touching misc.
#
# Exit codes:
#   0 — success, OR safely-skipped (wrong slot, or misc lacks expected
#       magic). Never block boot.

use strict;
use warnings;

my $MISC      = '/dev/disk/by-partlabel/misc';
my $BC_OFFSET = 0x800;
my $BC_LEN    = 0x20;

# 1. Confirm we're booted on slot A.
my $cmdline = '';
if (open my $cl, '<', '/proc/cmdline') {
    local $/;
    $cmdline = <$cl>;
    close $cl;
}
if ($cmdline !~ /androidboot\.slot_suffix=_a\b/) {
    warn "c60-mark-slot-success: not on slot A (cmdline lacks androidboot.slot_suffix=_a); skipping\n";
    exit 0;
}

# 2. Read misc bytes 0x800..0x81f.
my $fh;
unless (open $fh, '+<:raw', $MISC) {
    warn "c60-mark-slot-success: cannot open $MISC: $!\n";
    exit 0;
}
unless (sysseek $fh, $BC_OFFSET, 0) {
    warn "c60-mark-slot-success: seek to $BC_OFFSET failed: $!\n";
    close $fh;
    exit 0;
}
my $bc = '';
my $r = sysread $fh, $bc, $BC_LEN;
unless (defined $r && $r == $BC_LEN) {
    warn "c60-mark-slot-success: short read at $BC_OFFSET ($r/$BC_LEN)\n";
    close $fh;
    exit 0;
}

# 3. Validate magic. Expected: 00 41 42 30 ('\0AB0') at offset 0..3.
my @b = unpack 'C*', $bc;
my $magic_ok = ($b[0] == 0x00 && $b[1] == 0x41 && $b[2] == 0x42 && $b[3] == 0x30);
unless ($magic_ok) {
    my $hex = join(' ', map { sprintf '%02x', $_ } @b[0..3]);
    warn "c60-mark-slot-success: misc lacks NXP boot_control magic at 0x800 (got $hex, expected 00 41 42 30); refusing to write\n";
    close $fh;
    exit 0;
}

# 4. Check idempotency: if tries == 0 AND successful == 1 already, only
# rewrite if the stored CRC is also valid; otherwise skip the write.
my $cur_tries = $b[9];
my $cur_succ  = $b[10];

# 5. Mutate slot A fields.
$b[9]  = 0;  # tries_remaining
$b[10] = 1;  # successful_boot

# 6. Recompute CRC32 over bytes 0..0x1b (polynomial 0xEDB88320, init 0xffffffff,
# xor-out 0xffffffff, reflected — standard zlib / Ethernet CRC32).
sub crc32 {
    my @data = @_;
    my $crc = 0xffffffff;
    for my $byte (@data) {
        $crc ^= $byte;
        for (1 .. 8) {
            if ($crc & 1) {
                $crc = ($crc >> 1) ^ 0xEDB88320;
            } else {
                $crc >>= 1;
            }
            $crc &= 0xffffffff;
        }
    }
    return ($crc ^ 0xffffffff) & 0xffffffff;
}

my $crc = crc32(@b[0..0x1b]);

# Big-endian CRC bytes at 0x1c..0x1f.
$b[0x1c] = ($crc >> 24) & 0xff;
$b[0x1d] = ($crc >> 16) & 0xff;
$b[0x1e] = ($crc >>  8) & 0xff;
$b[0x1f] = ($crc >>  0) & 0xff;

my $new_bc = pack 'C*', @b;

# 7. If the recomputed-and-mutated buffer is byte-for-byte equal to what
# was already there, this is an idempotent no-op — skip the write.
if ($new_bc eq $bc) {
    print "c60-mark-slot-success: slot A already marked tries=0 successful=1 with valid CRC (no-op)\n";
    close $fh;
    exit 0;
}

# 8. Write back.
unless (sysseek $fh, $BC_OFFSET, 0) {
    warn "c60-mark-slot-success: seek before write failed: $!\n";
    close $fh;
    exit 0;
}
my $w = syswrite $fh, $new_bc, $BC_LEN;
unless (defined $w && $w == $BC_LEN) {
    warn "c60-mark-slot-success: short write at $BC_OFFSET ($w/$BC_LEN): $!\n";
    close $fh;
    exit 0;
}
close $fh;

printf "c60-mark-slot-success: slot A marked tries=0 successful=1, CRC=0x%08x (was tries=%d successful=%d)\n",
    $crc, $cur_tries, $cur_succ;
exit 0;
