package TDone::TUI;
use strict;
use warnings;
use List::Util qw(max min);
use Term::ReadKey;
use Term::ReadLine;

use TDone qw($W_ID $W_STATUS $W_PROJECT $W_SCHED $W_DUE $W_PRI $W_TAGS @TABLE_HEADERS);

use constant {
    CLEAR    => "\033[2J\033[H",
    CLR_EOL  => "\033[K",
    BOLD     => "\033[1m",
    REVERSE  => "\033[7m",
    YELLOW   => "\033[33m",
    CYAN     => "\033[36m",
    RESET    => "\033[0m",
};

sub esc      { "\033[$_[0]" }
sub goto_pos { "\033[$_[0];$_[1]H" }

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

my $tui_rl;

sub tui_prompt {
    my ($rows, $cols, $prompt, $prefill) = @_;
    $prefill //= '';

    $tui_rl //= Term::ReadLine->new('tdone');

    ReadMode('restore');
    print goto_pos($rows, 1), CLR_EOL;
    my $input = $tui_rl->readline($prompt, $prefill) // '';
    ReadMode('raw');
    return $input;
}

sub tui_draw {
    my ($rows, $cols, $row_map, $cur, $scroll, $search_hl, $todos_by_id) = @_;
    print CLEAR;
    my ($title_w, $hdr) = TDone::table_layout($cols);
    print BOLD, $hdr, RESET, "\n";
    print '-' x $cols, "\n";

    my $visible = $rows - 2;
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
            my $status = TDone::display_status($t, $todos_by_id);
            my $star   = $t->{description} ? '*' : ' ';
            my $title  = substr($t->{title} // '', 0, $title_w);

            # Highlight search match in title
            if ($search_hl && $title =~ /\Q$search_hl\E/i) {
                (my $ht = $title) =~ s/(\Q$search_hl\E)/YELLOW.BOLD.$1.RESET.($is_cur ? REVERSE : '')/ige;
                # Pad using the visible length of $title (before ANSI codes were added)
                my $ht_padded = $ht . (' ' x max(0, $title_w - length($title)));
                printf "%s%-${W_ID}s %-${W_STATUS}s %-${W_PROJECT}s %s %-${W_SCHED}.${W_SCHED}s %-${W_DUE}.${W_DUE}s %-${W_PRI}s %-${W_TAGS}s%s%s\n",
                    $pfx,
                    $t->{id} // '', substr($status, 0, $W_STATUS),
                    substr($t->{project} // '', 0, $W_PROJECT),
                    $ht_padded,
                    TDone::fmt_date($t->{scheduled}), TDone::fmt_date($t->{due}),
                    substr($t->{priority} // '', 0, $W_PRI),
                    substr($t->{tags} // '', 0, $W_TAGS),
                    $star, $sfx;
            } else {
                printf "%s%-${W_ID}s %-${W_STATUS}s %-${W_PROJECT}s %-*s %-${W_SCHED}.${W_SCHED}s %-${W_DUE}.${W_DUE}s %-${W_PRI}s %-${W_TAGS}s%s%s\n",
                    $pfx,
                    $t->{id} // '', substr($status, 0, $W_STATUS),
                    substr($t->{project} // '', 0, $W_PROJECT),
                    $title_w, $title,
                    TDone::fmt_date($t->{scheduled}), TDone::fmt_date($t->{due}),
                    substr($t->{priority} // '', 0, $W_PRI),
                    substr($t->{tags} // '', 0, $W_TAGS),
                    $star, $sfx;
            }
        }
    }
}

# Return indices into @$row_map that match the search term
sub search_indices {
    my ($row_map, $search) = @_;
    return () unless $search;
    my $sl = lc $search;
    my @matches;
    for my $i (0 .. $#$row_map) {
        my $rm = $row_map->[$i];
        next if $rm->{type} eq 'desc';
        my $t = $rm->{todo};
        if (index(lc($t->{title}       // ''), $sl) >= 0 ||
            index(lc($t->{description} // ''), $sl) >= 0) {
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

            my @all_todos   = TDone::load_todos();
            my %todos_by_id = map { $_->{id} => $_ } @all_todos;
            my @disp = TDone::get_list_todos(@list_args);

            # Build row map (todo rows + optional expanded description rows)
            my @row_map;
            for my $t (@disp) {
                push @row_map, { todo => $t, type => 'todo' };
                if ($expanded{$t->{id} // 0} && $t->{description}) {
                    push @row_map, { todo => $t, type => 'desc' };
                }
            }

            # Clamp cursor
            $cur = 0 unless @row_map;
            $cur = 0          if $cur < 0;
            $cur = $#row_map  if @row_map && $cur > $#row_map;

            # Adjust scroll
            my $visible = max(1, $rows - 2);
            $scroll = $cur                    if $cur < $scroll;
            $scroll = $cur - $visible + 1     if $cur >= $scroll + $visible;
            $scroll = 0                       if $scroll < 0;

            tui_draw($rows, $cols, \@row_map, $cur, $scroll,
                     $search, \%todos_by_id);

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

            # ---- scroll half/full screen ----
            elsif ($k eq 'd' || $k eq "\x04") {          # d / Ctrl-D: half down
                my $half = max(1, int($visible / 2));
                $cur = min($#row_map, $cur + $half);
            }
            elsif ($k eq 'u' || $k eq "\x15") {          # u / Ctrl-U: half up
                my $half = max(1, int($visible / 2));
                $cur = max(0, $cur - $half);
            }
            elsif ($k eq ' ' || $k eq "\x16" || $k eq 'f' || $k eq "\x06") {
                # space / Ctrl-V / f / Ctrl-F: full screen down
                $cur = min($#row_map, $cur + $visible);
            }
            elsif ($k eq 'b' || $k eq "\x02") {          # b / Ctrl-B: full screen up
                $cur = max(0, $cur - $visible);
            }

            # ESC and meta keys
            elsif ($k eq 'esc') { }     # standalone ESC — ignore
            elsif ($k eq 'meta') {
                my $mc = $key[1] // '';
                if    ($mc eq '<')        { $cur = 0; }
                elsif ($mc eq '>')        { $cur = max(0, $#row_map); }
                elsif (lc($mc) eq 'u')    { $search = ''; }
                elsif ($mc eq 'v' || $mc eq 'V') {   # ESC-v / Meta-v: full screen up
                    $cur = max(0, $cur - $visible);
                }
            }

            # ---- Enter: expand/collapse description ----
            elsif ($k eq "\r" || $k eq "\n" || $k eq "\x0d") {
                if (@row_map && $row_map[$cur]{type} eq 'todo') {
                    my $tid = $row_map[$cur]{todo}{id} // 0;
                    if ($expanded{$tid}) { delete $expanded{$tid}; }
                    else                 { $expanded{$tid} = 1;    }
                }
            }

            # ---- x: immediately toggle done state of current todo ----
            elsif ($k eq 'x') {
                if (@row_map) {
                    my $tid    = $row_map[$cur]{todo}{id} // 0;
                    my $status = $row_map[$cur]{todo}{status} // '';
                    if ($status eq 'done') {
                        eval { TDone::dispatch_command('x', '-r', $tid) };
                    } else {
                        eval { TDone::dispatch_command('x', $tid) };
                    }
                    warn $@ if $@;
                }
            }

            # ---- X: open prompt to mark a query of todos done ----
            elsif ($k eq 'X') {
                my $prefill  = 'x ';
                my $cmd_line = tui_prompt($rows, $cols, ':', $prefill);
                if ($cmd_line) {
                    eval { TDone::dispatch_command(split(/\s+/, $cmd_line)) };
                    warn $@ if $@;
                }
            }

            # ---- W: mark waiting via command prompt ----
            elsif ($k eq 'W') {
                if (@row_map) {
                    my $tid = $row_map[$cur]{todo}{id} // 0;
                    my $cmd_line = tui_prompt($rows, $cols, ':', "waiting $tid");
                    if ($cmd_line) {
                        eval { TDone::dispatch_command(split(/\s+/, $cmd_line)) };
                        warn $@ if $@;
                    }
                }
            }

            # ---- B: block current todo by a query of todos ----
            elsif ($k eq 'B') {
                if (@row_map) {
                    my $tid     = $row_map[$cur]{todo}{id} // 0;
                    my $prefill = "block -i $tid ";
                    my $cmd_line = tui_prompt($rows, $cols, ':', $prefill);
                    if ($cmd_line) {
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
                    if ($cmd_line) {
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
                    if ($cmd_line) {
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
                    if ($cmd_line) {
                        eval { TDone::dispatch_command(split(/\s+/, $cmd_line)) };
                        warn $@ if $@;
                        $cur-- if $cur > 0 && $cur >= $#row_map;
                    }
                }
            }

            # ---- +: add tag via command prompt (modify <id> -x <tag>) ----
            elsif ($k eq '+') {
                if (@row_map) {
                    my $tid     = $row_map[$cur]{todo}{id} // 0;
                    my $prefill = "modify $tid -x ";
                    my $cmd_line = tui_prompt($rows, $cols, ':', $prefill);
                    if ($cmd_line) {
                        eval { TDone::dispatch_command(split(/\s+/, $cmd_line)) };
                        warn $@ if $@;
                    }
                }
            }

            # ---- -: remove tag via command prompt (modify <id> -X <tag>) ----
            elsif ($k eq '-') {
                if (@row_map) {
                    my $tid     = $row_map[$cur]{todo}{id} // 0;
                    my $prefill = "modify $tid -X ";
                    my $cmd_line = tui_prompt($rows, $cols, ':', $prefill);
                    if ($cmd_line) {
                        eval { TDone::dispatch_command(split(/\s+/, $cmd_line)) };
                        warn $@ if $@;
                    }
                }
            }

            # ---- ^: set project via command prompt (modify <id> -p <project>) ----
            elsif ($k eq '^') {
                if (@row_map) {
                    my $tid     = $row_map[$cur]{todo}{id} // 0;
                    my $prefill = "modify $tid -p ";
                    my $cmd_line = tui_prompt($rows, $cols, ':', $prefill);
                    if ($cmd_line) {
                        eval { TDone::dispatch_command(split(/\s+/, $cmd_line)) };
                        warn $@ if $@;
                    }
                }
            }

            # ---- e: edit in $EDITOR via command prompt ----
            elsif ($k eq 'e') {
                if (@row_map) {
                    my $tid = $row_map[$cur]{todo}{id} // 0;
                    my $cmd_line = tui_prompt($rows, $cols, ':', "edit $tid");
                    if ($cmd_line) {
                        ReadMode('normal');
                        eval { TDone::dispatch_command(split(/\s+/, $cmd_line)) };
                        warn $@ if $@;
                        ReadMode('raw');
                    }
                }
            }

            # ---- E: immediately edit current todo in $EDITOR (no prompt) ----
            elsif ($k eq 'E') {
                if (@row_map) {
                    my $tid = $row_map[$cur]{todo}{id} // 0;
                    ReadMode('normal');
                    eval { TDone::dispatch_command('edit', $tid) };
                    warn $@ if $@;
                    ReadMode('raw');
                }
            }

            # ---- A: add a new todo via command prompt ----
            elsif ($k eq 'A') {
                my $cmd_line = tui_prompt($rows, $cols, ':', 'add ');
                if ($cmd_line) {
                    eval { TDone::dispatch_command(split(/\s+/, $cmd_line)) };
                    warn $@ if $@;
                }
            }

            # ---- /: less(1)-style search (highlight only, n/N to navigate) ----
            elsif ($k eq '/') {
                $search = tui_prompt($rows, $cols, '/');
                # Jump to first match
                if ($search) {
                    my @matches = search_indices(\@row_map, $search);
                    $cur = $matches[0] if @matches;
                } else {
                    # empty search — stay put
                }
            }

            # ---- n: next search match ----
            elsif ($k eq 'n') {
                if ($search) {
                    my @matches = search_indices(\@row_map, $search);
                    if (@matches) {
                        my ($next) = grep { $_ > $cur } @matches;
                        $next //= $matches[0];   # wrap around
                        $cur = $next;
                    }
                }
            }

            # ---- ? / N: previous search match (search backward) ----
            elsif ($k eq '?' || $k eq 'N') {
                if ($search) {
                    my @matches = search_indices(\@row_map, $search);
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
                if ($cmd_line) {
                    my @parts = split /\s+/, $cmd_line;
                    my $verb  = lc($parts[0] // '');
                    if ($verb eq 'list' || $verb eq 'ls') {
                        @list_args = @parts[1 .. $#parts];
                        $cur    = 0;
                        $scroll = 0;
                    }
                }
            }

            # ---- >: narrow by tag (-x flag) ----
            elsif ($k eq '>') {
                my $tag = tui_prompt($rows, $cols, 'Narrow by tag: ');
                if ($tag) {
                    push @list_args, '-x', $tag;
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
                if ($cmd_line) {
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

            # ---- ): narrow to current todo's project (-p flag) ----
            elsif ($k eq ')') {
                if (@row_map) {
                    my $proj = $row_map[$cur]{todo}{project} // '';
                    @list_args = ($proj ? ('-p', $proj) : ());
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
                my @bindings = (
                    [ 'j / ^N / Down',       'Move highlight down'                              ],
                    [ 'k / ^P / Up',         'Move highlight up'                                ],
                    [ 'g / ESC-<',           'Move to top'                                      ],
                    [ 'G / ESC->',           'Move to bottom'                                   ],
                    [ '^L',                  'Repaint screen'                                   ],
                    [ 'd / ^D',              'Scroll half a screen down'                        ],
                    [ 'u / ^U',              'Scroll half a screen up'                          ],
                    [ 'SPC / ^V / f / ^F',   'Scroll a full screen down'                        ],
                    [ 'b / ^B / ESC-v',      'Scroll a full screen up'                          ],
                    [ 'RET',                 'Expand/collapse todo description'                 ],
                    [ 'x',                   'Toggle current todo done/incomplete'              ],
                    [ 'X',                   'Prompt to mark a query of todos done'             ],
                    [ 'W',                   'Mark todo waiting'                                ],
                    [ 'B',                   'Prompt to block current todo by a query of todos' ],
                    [ 'A',                   'Add a new todo'                                   ],
                    [ 'K',                   'Kill (delete) current todo'                       ],
                    [ 'S',                   'Set scheduled date (timespec)'                    ],
                    [ 'D',                   'Set due date (timespec)'                          ],
                    [ '+',                   'Add tag (modify <id> -x <tag>)'                   ],
                    [ '-',                   'Remove tag (modify <id> -X <tag>)'                ],
                    [ '^',                   'Set project (modify <id> -p <project>)'           ],
                    [ 'e',                   'Edit todo in $EDITOR (via prompt)'                ],
                    [ 'E',                   'Edit current todo immediately in $EDITOR'         ],
                    [ '/',                   'Search displayed rows (highlight only)'           ],
                    [ 'n',                   'Next search match'                                ],
                    [ '? / N',               'Previous search match (search backward)'         ],
                    [ '\\',                  'Open command prompt with :list'                   ],
                    [ '>',                   'Narrow by tag (-x)'                               ],
                    [ '<',                   'Clear list narrowing'                             ],
                    [ 'ESC-u / M-u',         'Clear search highlighting'                        ],
                    [ ':',                   'Enter command (list/ls updates display)'          ],
                    [ ')',                   "Narrow to current todo's project (-p)"            ],
                    [ '(',                   'Clear project narrowing'                          ],
                    [ 'h',                   'This help'                                        ],
                    [ 'q',                   'Quit'                                             ],
                );
                my $kw = max(map { length($_->[0]) } @bindings);
                print "tdone TUI key bindings:\n\n";
                printf "  %-*s  %s\n", $kw, $_->[0], $_->[1] for @bindings;
                print "\nPress any key...\n";
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
