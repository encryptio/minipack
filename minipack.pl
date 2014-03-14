#!/usr/bin/perl
use warnings;
use strict;

use JSON;

sub load_image {
    my ($file) = @_;

    # PAM format example:
    # P7
    # WIDTH 16
    # HEIGHT 16
    # DEPTH 4
    # MAXVAL 255
    # TUPLTYPE RGB_ALPHA
    # ENDHDR
    # <data>

    open my $lf, "-|", "convert", "-depth", "8", "-strip", "--", $file, "pam:-"
        or die "Couldn't run convert on $file: $!";

    my $magic = <$lf>;
    die "Bad magic from convert on $file\n" unless $magic eq "P7\n";

    my ($width, $height, $depth, $maxval, $tuple_type);
    while ( my $line = <$lf> ) {
        chomp $line;
        if ( $line eq "ENDHDR" ) {
            last;
        } elsif ( $line =~ /^WIDTH (\d+)$/ ) {
            $width = $1;
        } elsif ( $line =~ /^HEIGHT (\d+)$/ ) {
            $height = $1;
        } elsif ( $line =~ /^DEPTH (\d+)$/ ) {
            $depth = $1;
        } elsif ( $line =~ /^MAXVAL (\d+)$/ ) {
            $maxval = $1;
        } elsif ( $line =~ /^TUPLTYPE (.*)$/ ) {
            $tuple_type = $1;
        } else {
            die "Bad PAM header line \"$_\" from convert on $file\n";
        }
    }

    die "PAM didn't include required WIDTH field from convert on $file\n"
        unless defined $width;
    die "PAM didn't include required HEIGHT field from convert on $file\n"
        unless defined $height;
    die "PAM didn't include required DEPTH field from convert on $file\n"
        unless defined $depth;
    die "PAM didn't include required MAXVAL field from convert on $file\n"
        unless defined $maxval;
    die "PAM didn't include required TUPLTYPE field from convert on $file\n"
        unless defined $tuple_type;

    die "PAM had improper MAXVAL field of $maxval from convert on $file\n"
        if $maxval != 255;

    my $data = do { local $/; <$lf> };
    close $lf;

    if ( $tuple_type eq "RGB_ALPHA" ) {
        # rgba is native
    } elsif ( $tuple_type eq "RGB" ) {
        # need to add an all-ones alpha channel
        my $new = "\xFF" x ($width*$height*4);
        for my $y ( 0 .. $height-1 ) {
            my $in_row_offset = $y * $width*3;
            my $out_row_offset = $y * $width*4;
            for my $x ( 0 .. $width-1 ) {
                my $in_pix_offset = $in_row_offset + $x*3;
                my $out_pix_offset = $out_row_offset + $x*4;
                substr($new, $out_pix_offset, 3) = substr($data, $in_pix_offset, 3);
            }
        }
        $data = $new;
    } else {
        die "Unknown tuple type $tuple_type from convert on $file\n";
    }

    return {
        wid => $width,
        hei => $height,
        data => $data,
    };
}

sub save_image {
    my ($img, $to) = @_;

    open my $sf, "|-", "convert", "--", "pam:-", $to
        or die "Couldn't run convert for writing to $to: $!";

    print $sf "P7\n";
    print $sf "WIDTH $img->{wid}\n";
    print $sf "HEIGHT $img->{hei}\n";
    print $sf "DEPTH 4\n";
    print $sf "MAXVAL 255\n";
    print $sf "TUPLTYPE RGB_ALPHA\n";
    print $sf "ENDHDR\n";
    print $sf $img->{data};

    close $sf;
}

################################################################################

sub empty_tiling {
    return {
        saved => [],
        free => [],
        img => {
            wid => 0,
            hei => 0,
            data => "",
        },
    };
}

sub add_to_tiling {
    my ($tiling, $name, $img) = @_;

    # search for the smallest free block that's large enough
    my $best;
    for my $free ( @{$tiling->{'free'}} ) {
        if ( $free->[2] >= $img->{wid} and $free->[3] >= $img->{hei} ) {
            # candidate

            if ( not defined $best or $best->[2]*$best->[3] > $free->[2]*$free->[3] ) {
                $best = $free;
            }
        }
    }

    if ( defined $best ) {
        # can fit into an existing free block
        # we put it into the upper left corner of the free block

        # remove the free block from the tile free list
        for my $i ( 0 .. $#{$tiling->{'free'}} ) {
            if ( $tiling->{'free'}[$i] == $best ) {
                splice @{$tiling->{'free'}}, $i, 1;
                last;
            }
        }

        # add new free blocks if needed
        if ( $best->[2] > $img->{wid} ) {
            push @{$tiling->{'free'}}, [$best->[0]+$img->{wid}, $best->[1], $best->[2]-$img->{wid}, $best->[3]];
        }
        if ( $best->[3] > $img->{hei} ) {
            push @{$tiling->{'free'}}, [$best->[0], $best->[1]+$img->{hei}, $img->{wid}, $best->[3]-$img->{hei}];
        }

        # copy the image data
        my $row_length = $img->{wid}*4;
        for my $row ( 0 .. $img->{hei}-1 ) {
            my $to_y = $row + $best->[1];
            substr($tiling->{img}{data}, ($tiling->{img}{wid}*$to_y + $best->[0])*4, $row_length) =
                substr($img->{data}, $row*$row_length, $row_length);
        }

        # mark it for export
        push @{$tiling->{'saved'}}, {
            name => $name,
            wid => $img->{wid},
            hei => $img->{hei},
            x => $best->[0],
            y => $best->[1],
        };

        return;
    }

    # no existing free block can handle what we want. add more space.

    if ( $tiling->{img}{wid} > $tiling->{img}{hei} ) {
        # too wide, add space below the existing tiles and insert there.

        if ( $img->{wid} > $tiling->{img}{wid} ) {
            expand_tiling_width($tiling, $img->{wid} - $tiling->{img}{wid});
        }

        expand_tiling_height($tiling, $img->{hei});

        return add_to_tiling($tiling, $name, $img);
    } else {
        # too tall or square, add space to the right and insert there.

        if ( $img->{hei} > $tiling->{img}{hei} ) {
            expand_tiling_height($tiling, $img->{hei} - $tiling->{img}{hei});
        }

        expand_tiling_width($tiling, $img->{wid});

        return add_to_tiling($tiling, $name, $img);
    }
}

sub expand_tiling_width {
    my ($tiling, $space) = @_;

    if ( $tiling->{img}{hei} > 0 ) {
        push @{$tiling->{'free'}}, [$tiling->{img}{wid}, 0, $space, $tiling->{img}{hei}];
    }

    my $new_wid = $tiling->{img}{wid}+$space;

    my $new_data = "\x00" x (($tiling->{img}{wid}+$space)*$tiling->{img}{hei}*4);
    for my $row ( 0 .. $tiling->{img}{hei}-1 ) {
        substr($new_data, 4*$new_wid*$row, $tiling->{img}{wid}*4) =
            substr($tiling->{img}{data}, 4*$tiling->{img}{wid}*$row, 4*$tiling->{img}{wid});
    }

    $tiling->{img}{wid} = $new_wid;
    $tiling->{img}{data} = $new_data;
}

sub expand_tiling_height {
    my ($tiling, $space) = @_;

    if ( $tiling->{img}{wid} > 0 ) {
        push @{$tiling->{'free'}}, [0, $tiling->{img}{hei}, $tiling->{img}{wid}, $space];
    }

    $tiling->{img}{hei} += $space;
    $tiling->{img}{data} .= "\x00" x (4*$tiling->{img}{wid}*$space);
}

################################################################################

sub save_map {
    my ($tiling, $output_map, $output_image) = @_;

    my $out = {
        frames => {},
        meta => {
            app => "https://git.encryptio.com/minipack",
            version => "1.0",
            image => $output_image,
            format => "RGBA8888",
            size => {w => 0+$tiling->{img}{wid}, h => 0+$tiling->{img}{hei}},
            scale => "1",
        },
    };

    for my $save ( @{$tiling->{saved}} ) {
        my ($x,$y,$w,$h,$n) = @{$save}{qw/ x y wid hei name /};

        $_ = 0+$_ for $x, $y, $w, $h;

        $out->{frames}{$save->{name}} = {
            "frame" => {x => $x, y => $y, w => $w, h => $h},
            "rotated" => JSON::false,
            "trimmed" => JSON::false,
            "spriteSourceSize" => {x => 0, y => 0, w => $w, h => $h},
            "sourceSize" => {w => $w, h => $h},
        };
    }

    open my $sf, ">", $output_map or die "Couldn't open $output_map for writing: $!\n";
    print $sf to_json $out;
    close $sf;
}

################################################################################

sub show_help {
    print STDERR "Usage: $0 [-v] -o out.png -m out.json [--] input.png [input.png ...]\n";
}

# parse arguments
my @input_files;
my $output_image;
my $output_map;
my $verbose = 0;
while ( @ARGV ) {
    my $arg = shift;
    if ( $arg !~ /^-/ ) {
        push @input_files, $arg;
    } elsif ( $arg eq "--" ) {
        push @input_files, @ARGV;
        last;
    } elsif ( $arg eq "-o" ) {
        $output_image = shift;
    } elsif ( $arg eq "-m" ) {
        $output_map = shift;
    } elsif ( $arg eq "-h" or $arg eq "--help" ) {
        show_help();
        exit 0;
    } elsif ( $arg eq "-v" ) {
        $verbose = 1;
    } else {
        die "Unknown option $arg\n";
    }
}

if ( not defined $output_image or not defined $output_map ) {
    show_help();
    exit 1;
}

my @inputs;
for my $input_file ( @input_files ) {
    print STDERR "Loading image $input_file\n" if $verbose;
    push @inputs, { name => $input_file, image => load_image($input_file) };
}

@inputs =
    sort {
        $b->{image}{wid} <=> $a->{image}{wid} or
        $b->{image}{hei} <=> $a->{image}{hei} or
        $a->{name} cmp $b->{name}
    } @inputs;

my $tiling = empty_tiling;
for my $input ( @inputs ) {
    print STDERR "adding image $input->{name} ($input->{image}{wid}x$input->{image}{hei})\n" if $verbose;
    add_to_tiling($tiling, $input->{name}, $input->{image});
}

print STDERR "Writing $tiling->{img}{wid}x$tiling->{img}{hei} image to $output_image\n" if $verbose;
save_image $tiling->{img}, $output_image;

print STDERR "Writing tile map to $output_map\n" if $verbose;
save_map $tiling, $output_map, $output_image;
