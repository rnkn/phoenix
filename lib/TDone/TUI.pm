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
    my ($rows, $cols, $prompt, $prefill) = @_;
    $prefill //= '';
    print _goto($rows, 1), CLR_EOL, $prompt, $prefill;
    ReadMode('normal');
    my $input = <STDIN>;
    chomp $input if defined $input;
    ReadMode('raw');
    return $prefill . ($input // '');
}

sub tui_draw {
    my ($rows, $cols, $disp, $row_map, $cur, $scroll, $search_hl, $list_args) = @_;
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
        my $t      = $rm->{todo};
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
            if ($search_hl ne '' && $title =~ /\Q$search_hl\E/i) {
                (my $ht = $title) =~ s/(\Q$search_hl\E)/YELLOW.BOLD.$1.RESET.($is_cur ? REVERSE : '')/ige;
                # Pad using the visible length of $title (before ANSI codes were added)
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
    my @status_parts;
    push @status_parts, 'list:' . join(' ', @$list_args) if @$list_args;
    push @status_parts, "search:$search_hl"          if $search_hl ne '';
    my $filters = @status_parts ? '  [' . join(' ', @status_parts) . ']' : '';
    my $info = sprintf 'Todos: %d  Row: %d/%d%s  q:quit  h:help',
        scalar @$disp,
        (@$row_map ? $cur + 1 : 0), scalar @$row_map,
        $filters;
    print _goto($rows, 1), CLR_EOL, REVERSE,
          sprintf("%-*s", $cols, substr($info, 0, $cols)), RESET;
}

sub tui_update_todo {
    my ($id, %changes) = @_;
    my @all = TDone::load_tasks();
    for my $t (@all) {
        if (($t->{id} // 0) == $id) {
            $t->{$_} = $changes{$_} for keys %changes;
        }
    }
    TDone::save_tasks(@all);
}

# Return indices into @$row_map that match the search term
sub _search_indices {
    my ($row_map, $search) = @_;
    return () unless $search ne '';
    my $sl = lc $search;
    my @matches;
    for my $i (0 .. $#$row_map) {
        my $rm = $row_map->[$i];
        next if $rm->{type} eq 'desc';
        my $t = $rm->{todo};
        if (index(lc($t->{title}   // ''), $sl) >= 0 ||
            index(lc($t->{project} // ''), $sl) >= 0 ||
            index(lc($t->{tags}    // ''), $sl) >= 0) {
            push @matches, $i;
        }
    }
    return @matches;
}

sub cmd_ui {
    my $cur            = 0;
    my $scroll         = 0;
    my %expanded;
    my $search         = '';   # /  — highlight only, n/N navigation
    my @list_args      = ();   # list command args for filtering/narrowing

    ReadMode('raw');
    local $SIG{TERM} = sub { ReadMode('restore'); exit 0 };
    local $SIG{INT}  = sub { ReadMode('restore'); exit 0 };
    local $SIG{WINCH} = sub { };    # repaint on next loop

    my $ok = eval {
        my $quit = 0;
        while (!$quit) {
            my ($cols, $rows) = GetTerminalSize();
            $cols //= 80; $rows //= 24;

            my @disp = TDone::get_list_todos(@list_args);

            # Build row map (todo rows + optional expanded description rows)
            my @row_map;
            for my $t (@disp) {
                push @row_map, { todo => $t, type => 'todo' };
                if ($expanded{$t->{id} // 0} && ($t->{description} // '') ne '') {
                    push @row_map, { todo => $t, type => 'desc' };
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

            tui_draw($rows, $cols, \@disp, \@row_map, $cur, $scroll,
                     $search, \@list_args);

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
                if (@row_map && $row_map[$cur]{type} eq 'todo') {
                    my $tid = $row_map[$cur]{todo}{id} // 0;
                    if ($expanded{$tid}) { delete $expanded{$tid}; }
                    else                 { $expanded{$tid} = 1;    }
                }
            }

            # ---- X/x: toggle done/todo via command prompt ----
            elsif ($k eq 'X' || $k eq 'x') {
                if (@row_map) {
                    my $tid    = $row_map[$cur]{todo}{id} // 0;
                    my $status = $row_map[$cur]{todo}{status} // '';
                    my $verb   = $status eq 'done' ? 'reopen' : 'complete';
                    my $cmd_line = tui_prompt($rows, $cols, ':', "$verb $tid");
                    if ($cmd_line ne '') {
                        eval { TDone::dispatch_command(split(/\s+/, $cmd_line)) };
                        warn $@ if $@;
                    }
                }
            }

            # ---- W: mark waiting via command prompt ----
            elsif ($k eq 'W') {
                if (@row_map) {
                    my $tid = $row_map[$cur]{todo}{id} // 0;
                    my $cmd_line = tui_prompt($rows, $cols, ':', "waiting $tid");
                    if ($cmd_line ne '') {
                        eval { TDone::dispatch_command(split(/\s+/, $cmd_line)) };
                        warn $@ if $@;
                    }
                }
            }

            # ---- B: set blocked_by via command prompt ----
            elsif ($k eq 'B') {
                if (@row_map) {
                    my $tid = $row_map[$cur]{todo}{id} // 0;
                    my $prefill  = 'block ';
                    my $cmd_line = tui_prompt($rows, $cols, ':', $prefill);
                    # auto-append current todo id so user only types blocking id
                    $cmd_line .= " $tid" if length($cmd_line) > length($prefill);
                    if (length($cmd_line) > length($prefill)) {
                        eval { TDone::dispatch_command(split(/\s+/, $cmd_line)) };
                        warn $@ if $@;
                    }
                }
            }

            # ---- S: set scheduled date via command prompt ----
            elsif ($k eq 'S') {
                if (@row_map) {
                    my $tid = $row_map[$cur]{todo}{id} // 0;
                    my $cmd_line = tui_prompt($rows, $cols, ':', "schedule $tid -t ");
                    if ($cmd_line ne '') {
                        eval { TDone::dispatch_command(split(/\s+/, $cmd_line)) };
                        warn $@ if $@;
                    }
                }
            }

            # ---- D: set due date via command prompt ----
            elsif ($k eq 'D') {
                if (@row_map) {
                    my $tid = $row_map[$cur]{todo}{id} // 0;
                    my $cmd_line = tui_prompt($rows, $cols, ':', "due $tid -t ");
                    if ($cmd_line ne '') {
                        eval { TDone::dispatch_command(split(/\s+/, $cmd_line)) };
                        warn $@ if $@;
                    }
                }
            }

            # ---- K: kill (delete) current todo via command prompt ----
            elsif ($k eq 'K') {
                if (@row_map) {
                    my $tid = $row_map[$cur]{todo}{id} // 0;
                    my $cmd_line = tui_prompt($rows, $cols, ':', "kill $tid");
                    if ($cmd_line ne '') {
                        eval { TDone::dispatch_command(split(/\s+/, $cmd_line)) };
                        warn $@ if $@;
                        $cur-- if $cur > 0 && $cur >= $#row_map;
                    }
                }
            }

            # ---- +: add tags via command prompt ----
            elsif ($k eq '+') {
                if (@row_map) {
                    my $tid = $row_map[$cur]{todo}{id} // 0;
                    my $prefill  = 'tag -x ';
                    my $cmd_line = tui_prompt($rows, $cols, ':', $prefill);
                    # auto-append current todo id so user only types the tag name
                    $cmd_line .= " $tid" if length($cmd_line) > length($prefill);
                    if (length($cmd_line) > length($prefill)) {
                        eval { TDone::dispatch_command(split(/\s+/, $cmd_line)) };
                        warn $@ if $@;
                    }
                }
            }

            # ---- ^: set project (no CLI equivalent — direct update) ----
            elsif ($k eq '^') {
                my $proj = tui_prompt($rows, $cols, 'Set project: ');
                if (@row_map) {
                    my $tid = $row_map[$cur]{todo}{id} // 0;
                    tui_update_todo($tid, project => $proj);
                }
            }

            # ---- e: edit in $EDITOR via command prompt ----
            elsif ($k eq 'e') {
                if (@row_map) {
                    my $tid = $row_map[$cur]{todo}{id} // 0;
                    my $cmd_line = tui_prompt($rows, $cols, ':', "edit $tid");
                    if ($cmd_line ne '') {
                        ReadMode('normal');
                        eval { TDone::dispatch_command(split(/\s+/, $cmd_line)) };
                        warn $@ if $@;
                        ReadMode('raw');
                    }
                }
            }

            # ---- /: less(1)-style search (highlight only, n/N to navigate) ----
            elsif ($k eq '/') {
                $search = tui_prompt($rows, $cols, '/');
                # Jump to first match
                if ($search ne '') {
                    my @matches = _search_indices(\@row_map, $search);
                    $cur = $matches[0] if @matches;
                } else {
                    # empty search — stay put
                }
            }

            # ---- n: next search match ----
            elsif ($k eq 'n') {
                if ($search ne '') {
                    my @matches = _search_indices(\@row_map, $search);
                    if (@matches) {
                        my ($next) = grep { $_ > $cur } @matches;
                        $next //= $matches[0];   # wrap around
                        $cur = $next;
                    }
                }
            }

            # ---- ? / N: previous search match (search backward) ----
            elsif ($k eq '?' || $k eq 'N') {
                if ($search ne '') {
                    my @matches = _search_indices(\@row_map, $search);
                    if (@matches) {
                        my ($prev) = reverse grep { $_ < $cur } @matches;
                        $prev //= $matches[-1];  # wrap around
                        $cur = $prev;
                    }
                }
            }

            # ---- \: open command prompt pre-filled with :list ----
            elsif ($k eq '\\') {
                my $prefill  = 'list ';
                my $cmd_line = tui_prompt($rows, $cols, ':', $prefill);
                if (length($cmd_line) > length($prefill)) {
                    my @parts = split /\s+/, $cmd_line;
                    my $verb  = lc($parts[0] // '');
                    if ($verb eq 'list' || $verb eq 'ls') {
                        @list_args = @parts[1 .. $#parts];
                        $cur    = 0;
                        $scroll = 0;
                    }
                }
            }

            # ---- >: narrow by tag (appends to list query) ----
            elsif ($k eq '>') {
                my $tag = tui_prompt($rows, $cols, 'Narrow by tag: ');
                if ($tag ne '') {
                    push @list_args, $tag;
                    $cur    = 0;
                    $scroll = 0;
                }
            }

            # ---- <: clear list narrowing ----
            elsif ($k eq '<') {
                @list_args = ();
                $cur    = 0;
                $scroll = 0;
            }

            # ---- :: command prompt ----
            elsif ($k eq ':') {
                my $cmd_line = tui_prompt($rows, $cols, ':');
                if ($cmd_line ne '') {
                    my @parts = split /\s+/, $cmd_line;
                    my $verb  = lc($parts[0] // '');
                    if ($verb eq 'list' || $verb eq 'ls') {
                        @list_args = @parts[1 .. $#parts];
                        $cur    = 0;
                        $scroll = 0;
                    } elsif ($verb eq 'edit') {
                        ReadMode('normal');
                        eval { TDone::dispatch_command(@parts) };
                        warn $@ if $@;
                        ReadMode('raw');
                    } else {
                        eval { TDone::dispatch_command(@parts) };
                        warn $@ if $@;
                    }
                }
            }

            # ---- ): narrow to current todo's project ----
            elsif ($k eq ')') {
                if (@row_map) {
                    my $proj = $row_map[$cur]{todo}{project} // '';
                    @list_args = ($proj ne '' ? ($proj) : ());
                    $cur    = 0;
                    $scroll = 0;
                }
            }

            # ---- (: clear project narrowing ----
            elsif ($k eq '(') {
                @list_args = ();
                $cur    = 0;
                $scroll = 0;
            }

            # ---- h: help ----
            elsif ($k eq 'h') {
                ReadMode('normal');
                print CLEAR;
                print <<'HELP';
tdone TUI key bindings:

  j / ^N / Down   Move highlight down
  k / ^P / Up     Move highlight up
  g / ESC-<       Move to top
  G / ESC->       Move to bottom
  ^L              Repaint screen
  RET             Expand/collapse todo description
  X / x           Toggle todo done/incomplete
  W               Mark todo waiting
  B               Prompt for blocking todo ID
  K               Kill (delete) current todo
  S               Set scheduled date (timespec)
  D               Set due date (timespec)
  +               Add tags
  ^               Set project
  e               Edit todo in $EDITOR
  /               Search displayed rows (highlight only)
  n               Next search match
  ? / N           Previous search match (search backward)
  \               Open command prompt with :list
  >               Narrow by tag (appends to list query)
  <               Clear list narrowing
  ESC-u / M-u     Clear search highlighting
  :               Enter command (list <q> updates display)
  )               Narrow to current todo's project
  (               Clear project narrowing
  h               This help
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
