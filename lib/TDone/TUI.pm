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
    my ($rows, $cols, $disp, $row_map, $cur, $scroll, $search_hl, $narrow_project, $narrow_tags, $narrow_search) = @_;
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
    push @status_parts, "project:$narrow_project"    if $narrow_project ne '';
    push @status_parts, 'tag:' . join('+', @$narrow_tags) if @$narrow_tags;
    push @status_parts, "narrow:$narrow_search"      if $narrow_search ne '';
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
    my $narrow_search  = '';   # \  — narrows display
    my $narrow_project = '';   # )  — narrows to project
    my @narrow_tags    = ();   # >  — narrows by tag (AND)

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
            @disp = grep { ($_->{project} // '') eq $narrow_project } @disp
                if $narrow_project ne '';
            if (@narrow_tags) {
                for my $tag (@narrow_tags) {
                    my $tl = lc $tag;
                    @disp = grep {
                        grep { lc($_) eq $tl } split(/\s+/, $_->{tags} // '')
                    } @disp;
                }
            }
            if ($narrow_search ne '') {
                my $sl = lc $narrow_search;
                @disp = grep {
                    index(lc($_->{title}   // ''), $sl) >= 0 ||
                    index(lc($_->{project} // ''), $sl) >= 0 ||
                    index(lc($_->{tags}    // ''), $sl) >= 0
                } @disp;
            }
            @disp = TDone::sort_todos(@disp);

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
                     $search, $narrow_project, \@narrow_tags, $narrow_search);

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

            # ---- X/x: toggle done/todo ----
            elsif ($k eq 'X' || $k eq 'x') {
                if (@row_map) {
                    my $tid = $row_map[$cur]{todo}{id} // 0;
                    my @all2 = TDone::load_tasks();
                    for my $t (@all2) {
                        if (($t->{id} // 0) == $tid) {
                            $t->{status} = ($t->{status}//'') eq 'done' ? 'todo' : 'done';
                        }
                    }
                    TDone::save_tasks(@all2);
                }
            }

            # ---- W: mark waiting ----
            elsif ($k eq 'W') {
                if (@row_map) {
                    my $tid = $row_map[$cur]{todo}{id} // 0;
                    tui_update_todo($tid, status => 'waiting');
                }
            }

            # ---- B: set blocked_by ----
            elsif ($k eq 'B') {
                my $bid = tui_prompt($rows, $cols, 'Block by todo ID: ');
                if ($bid =~ /^\d+$/ && @row_map) {
                    my $tid = $row_map[$cur]{todo}{id} // 0;
                    tui_update_todo($tid, blocked_by => $bid);
                }
            }

            # ---- S: set scheduled date ----
            elsif ($k eq 'S') {
                my $ds = tui_prompt($rows, $cols, 'Schedule (timespec): ');
                if ($ds ne '' && @row_map) {
                    my $tid = $row_map[$cur]{todo}{id} // 0;
                    tui_update_todo($tid, scheduled => TDone::parse_timespec($ds));
                }
            }

            # ---- D: set due date ----
            elsif ($k eq 'D') {
                my $ds = tui_prompt($rows, $cols, 'Due (timespec): ');
                if ($ds ne '' && @row_map) {
                    my $tid = $row_map[$cur]{todo}{id} // 0;
                    tui_update_todo($tid, due => TDone::parse_timespec($ds));
                }
            }

            # ---- K: kill (delete) current todo ----
            elsif ($k eq 'K') {
                if (@row_map) {
                    my $tid = $row_map[$cur]{todo}{id} // 0;
                    my @all2 = TDone::load_tasks();
                    TDone::save_tasks(grep { ($_->{id} // 0) != $tid } @all2);
                    $cur-- if $cur > 0 && $cur >= $#row_map;
                }
            }

            # ---- +: add tags ----
            elsif ($k eq '+') {
                my $tags = tui_prompt($rows, $cols, 'Add tags: ');
                if ($tags ne '' && @row_map) {
                    my $tid = $row_map[$cur]{todo}{id} // 0;
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
                    my $tid = $row_map[$cur]{todo}{id} // 0;
                    tui_update_todo($tid, project => $proj);
                }
            }

            # ---- e: edit in $EDITOR ----
            elsif ($k eq 'e') {
                if (@row_map) {
                    my $tid = $row_map[$cur]{todo}{id} // 0;
                    ReadMode('normal');
                    my @all2 = TDone::load_tasks();
                    for my $t (@all2) {
                        TDone::edit_task_yaml($t) if ($t->{id} // 0) == $tid;
                    }
                    TDone::save_tasks(@all2);
                    ReadMode('raw');
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

            # ---- \: search-based narrowing (old / behaviour) ----
            elsif ($k eq '\\') {
                $narrow_search = tui_prompt($rows, $cols, '\\');
                $cur    = 0;
                $scroll = 0;
            }

            # ---- >: narrow by tag (AND) ----
            elsif ($k eq '>') {
                my $tag = tui_prompt($rows, $cols, 'Narrow by tag: ');
                if ($tag ne '') {
                    push @narrow_tags, $tag;
                    $cur    = 0;
                    $scroll = 0;
                }
            }

            # ---- <: clear tag / search narrowing ----
            elsif ($k eq '<') {
                @narrow_tags   = ();
                $narrow_search = '';
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
                        # Apply list filter as narrow_search so the UI updates
                        my @fargs = @parts[1 .. $#parts];
                        $narrow_search = join(' ', grep { !/^-/ } @fargs);
                        $cur    = 0;
                        $scroll = 0;
                    } else {
                        eval { TDone::dispatch_command(@parts) };
                        warn $@ if $@;
                    }
                }
            }

            # ---- ): narrow to current todo's project ----
            elsif ($k eq ')') {
                if (@row_map) {
                    $narrow_project = $row_map[$cur]{todo}{project} // '';
                    $cur    = 0;
                    $scroll = 0;
                }
            }

            # ---- (: clear project narrowing ----
            elsif ($k eq '(') {
                $narrow_project = '';
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
  \               Narrow display by search term
  >               Narrow by tag (AND; repeat to add more)
  <               Clear tag/search narrowing
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
