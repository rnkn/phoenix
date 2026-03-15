package TDone::TUI;
use strict;
use warnings;
use utf8;
use List::Util    qw(max);
use Term::ReadKey;

use TDone;

use constant {
    CLEAR    => "\033[2J\033[H",
    CLR_EOL  => "\033[K",
    BOLD     => "\033[1m",
    REVERSE  => "\033[7m",
    YELLOW   => "\033[33m",
    CYAN     => "\033[36m",
    RESET    => "\033[0m",
};

sub _esc  { "\033[$_[0]" }
sub _goto { "\033[$_[0];$_[1]H" }

sub tui_read_key {
    my $ch = ReadKey(0);
    return ('') unless defined $ch;
    if (ord($ch) == 27) {                        # ESC
        my $c2 = ReadKey(0.15);
        return ('esc') unless defined $c2;
        if ($c2 eq '[') {
            my $c3 = ReadKey(0.05) // '';
            # consume extra bytes for longer sequences
            if ($c3 =~ /[0-9;]/) {
                my $extra = ReadKey(0.05) // '';
                return ('csi', $c3 . $extra);
            }
            return ('up')    if $c3 eq 'A';
            return ('down')  if $c3 eq 'B';
            return ('right') if $c3 eq 'C';
            return ('left')  if $c3 eq 'D';
            return ('csi', $c3);
        }
        return ('meta', $c2);
    }
    return ($ch);
}

sub tui_prompt {
    my ($rows, $cols, $prompt) = @_;
    print _goto($rows, 1), CLR_EOL, $prompt;
    ReadMode('normal');
    my $input = <STDIN>;
    chomp $input if defined $input;
    ReadMode('raw');
    return $input // '';
}

sub tui_draw {
    my ($rows, $cols, $disp, $row_map, $cur, $scroll, $search, $narrow) = @_;
    print CLEAR;
    my $title_w = max(10, $cols - 85);
    printf BOLD . "%-4s %-9s %-12s %-*s %-14s %-14s %-4s %s\n" . RESET,
        'ID', 'STATUS', 'PROJECT', $title_w, 'TITLE',
        'SCHEDULED', 'DUE', 'PRI', 'TAGS';
    print '-' x $cols, "\n";

    my $visible = $rows - 3;
    $visible = 1 if $visible < 1;

    for my $i ($scroll .. $scroll + $visible - 1) {
        last if $i >= @$row_map;
        my $rm     = $row_map->[$i];
        my $t      = $rm->{task};
        my $is_cur = ($i == $cur);
        my $pfx    = $is_cur ? REVERSE : '';
        my $sfx    = $is_cur ? RESET   : '';

        if ($rm->{type} eq 'desc') {
            my $desc = $t->{description} // '';
            $desc =~ s/\n/ | /g;
            printf "%s    %-*s%s\n", $pfx, $cols - 5, substr($desc, 0, $cols - 5), $sfx;
        } else {
            my $status = TDone::display_status($t);
            my $star   = ($t->{description} // '') ne '' ? '*' : ' ';
            my $title  = substr($t->{title} // '', 0, $title_w);

            # Highlight search match in title
            if ($search ne '' && $title =~ /\Q$search\E/i) {
                (my $ht = $title) =~ s/(\Q$search\E)/YELLOW.BOLD.$1.RESET.($is_cur ? REVERSE : '')/ige;
                # Pad using the visible length of $title (before ANSI codes were added)
                # so that subsequent columns are correctly aligned despite the invisible codes.
                my $ht_padded = $ht . (' ' x max(0, $title_w - length($title)));
                printf "%s%-4s %-9s %-12s %s %-14.14s %-14.14s %-4s %-20s%s%s\n",
                    $pfx,
                    $t->{id} // '', substr($status, 0, 9),
                    substr($t->{project} // '', 0, 12),
                    $ht_padded,
                    TDone::fmt_date($t->{scheduled}), TDone::fmt_date($t->{due}),
                    substr($t->{priority} // '', 0, 4),
                    substr($t->{tags} // '', 0, 20),
                    $star, $sfx;
            } else {
                printf "%s%-4s %-9s %-12s %-*s %-14.14s %-14.14s %-4s %-20s%s%s\n",
                    $pfx,
                    $t->{id} // '', substr($status, 0, 9),
                    substr($t->{project} // '', 0, 12),
                    $title_w, $title,
                    TDone::fmt_date($t->{scheduled}), TDone::fmt_date($t->{due}),
                    substr($t->{priority} // '', 0, 4),
                    substr($t->{tags} // '', 0, 20),
                    $star, $sfx;
            }
        }
    }

    # Status bar
    my $info = sprintf 'Tasks: %d  Row: %d/%d%s%s  q:quit  ?:help',
        scalar @$disp,
        (@$row_map ? $cur + 1 : 0), scalar @$row_map,
        $narrow ne '' ? "  [project:$narrow]" : '',
        $search ne '' ? "  [search:$search]"  : '';
    print _goto($rows, 1), CLR_EOL, REVERSE,
          sprintf("%-*s", $cols, substr($info, 0, $cols)), RESET;
}

sub tui_update_task {
    my ($id, %changes) = @_;
    my @all = TDone::load_tasks();
    for my $t (@all) {
        if (($t->{id} // 0) == $id) {
            $t->{$_} = $changes{$_} for keys %changes;
        }
    }
    TDone::save_tasks(@all);
}

sub cmd_ui {
    my $cur     = 0;
    my $scroll  = 0;
    my %expanded;
    my $search  = '';
    my $narrow  = '';

    ReadMode('raw');
    local $SIG{TERM} = sub { ReadMode('restore'); exit 0 };
    local $SIG{INT}  = sub { ReadMode('restore'); exit 0 };
    local $SIG{WINCH} = sub { };    # repaint on next loop

    my $ok = eval {
        my $quit = 0;
        while (!$quit) {
            my ($cols, $rows) = GetTerminalSize();
            $cols //= 80; $rows //= 24;

            my @all  = TDone::load_tasks();
            my @disp = @all;
            @disp = grep { ($_->{project} // '') eq $narrow } @disp if $narrow ne '';
            if ($search ne '') {
                my $sl = lc $search;
                @disp = grep {
                    index(lc($_->{title}   // ''), $sl) >= 0 ||
                    index(lc($_->{project} // ''), $sl) >= 0 ||
                    index(lc($_->{tags}    // ''), $sl) >= 0
                } @disp;
            }
            @disp = TDone::sort_tasks(@disp);

            # Build row map (task rows + optional expanded description rows)
            my @row_map;
            for my $t (@disp) {
                push @row_map, { task => $t, type => 'task' };
                if ($expanded{$t->{id} // 0} && ($t->{description} // '') ne '') {
                    push @row_map, { task => $t, type => 'desc' };
                }
            }

            # Clamp cursor
            $cur = 0 unless @row_map;
            $cur = 0          if $cur < 0;
            $cur = $#row_map  if @row_map && $cur > $#row_map;

            # Adjust scroll
            my $visible = max(1, $rows - 3);
            $scroll = $cur                    if $cur < $scroll;
            $scroll = $cur - $visible + 1     if $cur >= $scroll + $visible;
            $scroll = 0                       if $scroll < 0;

            tui_draw($rows, $cols, \@disp, \@row_map, $cur, $scroll, $search, $narrow);

            my @key = tui_read_key();
            my $k   = $key[0] // '';

            # ---- navigation ----
            if    ($k eq 'q' || $k eq 'Q') { $quit = 1; }
            elsif ($k eq 'j' || $k eq "\x0e" || $k eq 'down') {
                $cur++ if $cur < $#row_map;
            }
            elsif ($k eq 'k' || $k eq "\x10" || $k eq 'up') {
                $cur-- if $cur > 0;
            }
            elsif ($k eq 'g') { $cur = 0; }
            elsif ($k eq 'G') { $cur = max(0, scalar(@row_map) - 1); }
            elsif ($k eq "\x0c") { }    # ^L — just repaint

            # ESC and meta keys
            elsif ($k eq 'esc') { }     # standalone ESC — ignore
            elsif ($k eq 'meta') {
                my $mc = $key[1] // '';
                if    ($mc eq '<')        { $cur = 0; }
                elsif ($mc eq '>')        { $cur = max(0, $#row_map); }
                elsif (lc($mc) eq 'u')    { $search = ''; }
            }

            # ---- Enter: expand/collapse description ----
            elsif ($k eq "\r" || $k eq "\n" || $k eq "\x0d") {
                if (@row_map && $row_map[$cur]{type} eq 'task') {
                    my $tid = $row_map[$cur]{task}{id} // 0;
                    if ($expanded{$tid}) { delete $expanded{$tid}; }
                    else                 { $expanded{$tid} = 1;    }
                }
            }

            # ---- c: toggle complete/todo ----
            elsif ($k eq 'c') {
                if (@row_map) {
                    my $tid = $row_map[$cur]{task}{id} // 0;
                    my @all2 = TDone::load_tasks();
                    for my $t (@all2) {
                        if (($t->{id} // 0) == $tid) {
                            $t->{status} = ($t->{status}//'') eq 'complete' ? 'todo' : 'complete';
                        }
                    }
                    TDone::save_tasks(@all2);
                }
            }

            # ---- w: mark waiting ----
            elsif ($k eq 'w') {
                if (@row_map) {
                    my $tid = $row_map[$cur]{task}{id} // 0;
                    tui_update_task($tid, status => 'waiting');
                }
            }

            # ---- b: set blocked_by ----
            elsif ($k eq 'b') {
                my $bid = tui_prompt($rows, $cols, 'Block by task ID: ');
                if ($bid =~ /^\d+$/ && @row_map) {
                    my $tid = $row_map[$cur]{task}{id} // 0;
                    tui_update_task($tid, blocked_by => $bid);
                }
            }

            # ---- s: set scheduled date ----
            elsif ($k eq 's') {
                my $ds = tui_prompt($rows, $cols, 'Schedule (timespec): ');
                if ($ds ne '' && @row_map) {
                    my $tid = $row_map[$cur]{task}{id} // 0;
                    tui_update_task($tid, scheduled => TDone::parse_timespec($ds));
                }
            }

            # ---- d: set due date ----
            elsif ($k eq 'd') {
                my $ds = tui_prompt($rows, $cols, 'Due (timespec): ');
                if ($ds ne '' && @row_map) {
                    my $tid = $row_map[$cur]{task}{id} // 0;
                    tui_update_task($tid, due => TDone::parse_timespec($ds));
                }
            }

            # ---- +: add tags ----
            elsif ($k eq '+') {
                my $tags = tui_prompt($rows, $cols, 'Add tags: ');
                if ($tags ne '' && @row_map) {
                    my $tid = $row_map[$cur]{task}{id} // 0;
                    my @all2 = TDone::load_tasks();
                    for my $t (@all2) {
                        if (($t->{id} // 0) == $tid) {
                            $t->{tags} = join(' ', grep { $_ ne '' }
                                split(/\s+/, $t->{tags} // ''), split(/\s+/, $tags));
                        }
                    }
                    TDone::save_tasks(@all2);
                }
            }

            # ---- ^: set project ----
            elsif ($k eq '^') {
                my $proj = tui_prompt($rows, $cols, 'Set project: ');
                if (@row_map) {
                    my $tid = $row_map[$cur]{task}{id} // 0;
                    tui_update_task($tid, project => $proj);
                }
            }

            # ---- e: edit in $EDITOR ----
            elsif ($k eq 'e') {
                if (@row_map) {
                    my $tid = $row_map[$cur]{task}{id} // 0;
                    ReadMode('normal');
                    my @all2 = TDone::load_tasks();
                    for my $t (@all2) {
                        TDone::edit_task_yaml($t) if ($t->{id} // 0) == $tid;
                    }
                    TDone::save_tasks(@all2);
                    ReadMode('raw');
                }
            }

            # ---- /: search ----
            elsif ($k eq '/') {
                $search = tui_prompt($rows, $cols, '/');
                $cur    = 0;
                $scroll = 0;
            }

            # ---- :: command prompt ----
            elsif ($k eq ':') {
                my $cmd_line = tui_prompt($rows, $cols, ':');
                if ($cmd_line ne '') {
                    ReadMode('normal');
                    print "\n";
                    eval { TDone::dispatch_command(split /\s+/, $cmd_line) };
                    warn $@ if $@;
                    print "\nPress any key to continue...";
                    ReadMode('raw');
                    ReadKey(0);
                }
            }

            # ---- ): narrow to current task's project ----
            elsif ($k eq ')') {
                if (@row_map) {
                    $narrow = $row_map[$cur]{task}{project} // '';
                    $cur    = 0;
                    $scroll = 0;
                }
            }

            # ---- (: clear narrowing ----
            elsif ($k eq '(') {
                $narrow = '';
                $cur    = 0;
                $scroll = 0;
            }

            # ---- ?: help ----
            elsif ($k eq '?') {
                ReadMode('normal');
                print CLEAR;
                print <<'HELP';
tdone TUI key bindings:

  j / ^N / Down   Move highlight down
  k / ^P / Up     Move highlight up
  g / ESC-<       Move to top
  G / ESC->       Move to bottom
  ^L              Repaint screen
  RET             Expand/collapse task description
  c               Toggle task complete/incomplete
  w               Mark task waiting
  b               Prompt for blocking task ID
  s               Set scheduled date (timespec)
  d               Set due date (timespec)
  +               Add tags
  ^               Set project
  e               Edit task in $EDITOR
  /               Search tasks
  ESC-u / M-u     Clear search highlighting
  :               Enter command
  )               Narrow to current task's project
  (               Clear narrowing
  q               Quit

Press any key...
HELP
                ReadMode('raw');
                ReadKey(0);
            }
        }
        1;
    };

    ReadMode('restore');
    print CLEAR;
    die $@ if !$ok && $@;
}

1;
