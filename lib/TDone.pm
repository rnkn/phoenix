package TDone;
use strict;
use warnings;
use parent 'Exporter';
use POSIX         qw(strftime mktime);
use File::Temp    qw(tempfile);
use Path::Tiny;
use List::Util    qw(max);
use Getopt::Std   qw(getopts);
use YAML::Tiny;
use Term::ReadKey;

our $VERSION = '0.1.0';
our @EXPORT_OK = qw($W_ID $W_STATUS $W_PROJECT $W_SCHED $W_DUE $W_PRI $W_TAGS @TABLE_HEADERS);

# ============================================================
# DATA FILE
# ============================================================

my @FIELDS = qw(id status project title scheduled due priority blocked_by tags description);

our $W_ID      =  4;
our $W_STATUS  =  9;
our $W_PROJECT = 12;
our $W_SCHED   = 14;
our $W_DUE     = 14;
our $W_PRI     =  4;
our $W_TAGS    = 30;
our @TABLE_HEADERS = qw(id status project title scheduled due pri tags);

sub data_file {
    return $ENV{TDONE_FILE} if $ENV{TDONE_FILE};
    my $dir = "$ENV{HOME}/.tdone";
    path($dir)->mkpath unless -d $dir;
    return "$dir/todo.tsv";
}

sub load_todos {
    my $file = data_file();
    return () unless -f $file;
    my @todos;
    for (path($file)->lines_utf8({chomp => 1})) {
        next if /^\s*$/;
        my @vals = split /\t/, $_, scalar @FIELDS;
        push @vals, '' while @vals < scalar @FIELDS;
        my %t;
        @t{@FIELDS} = @vals;
        $t{description} =~ s/\\n/\n/g;
        push @todos, \%t;
    }
    return @todos;
}

sub save_todos {
    my @todos = @_;
    my $file = data_file();
    my @lines;
    for my $t (@todos) {
        my @vals = map {
            my $v = $t->{$_} // '';
            $v =~ s/\t/    /g;
            $v =~ s/\r?\n/\\n/g if $_ eq 'description';
            $v
        } @FIELDS;
        push @lines, join("\t", @vals) . "\n";
    }
    path($file)->spew_utf8(@lines);
}

sub next_id {
    my @todos = @_;
    my $max = 0;
    $max < ($_ // 0) and $max = $_ for map { $_->{id} } @todos;
    return $max + 1;
}

# ============================================================
# TIME PARSING
# ============================================================

my %DAY_MAP = (
    sunday    => 0, monday  => 1, tuesday   => 2, wednesday => 3,
    thursday  => 4, friday  => 5, saturday  => 6,
    sun => 0, mon => 1, tue => 2, wed => 3, thu => 4, fri => 5, sat => 6,
);

my %MONTH_MAP = (
    january   => 0, february => 1, march    => 2, april    => 3,
    may       => 4, june     => 5, july     => 6, august   => 7,
    september => 8, october  => 9, november => 10, december => 11,
    jan => 0, feb => 1, mar => 2, apr => 3, jun => 5,
    jul => 6, aug => 7, sep => 8, oct => 9, nov => 10, dec => 11,
);

# A valid 5-field crontab expression, e.g. "0 0 * * *" or "*/15 6-22 1,15 * 1-5"
sub is_cron_expr {
    my ($s) = @_;
    return unless $s;
    return $s =~ /^[\d\*\/,\-]+(?:\s+[\d\*\/,\-]+){4}$/;
}

sub parse_timespec {
    my ($spec) = @_;
    return unless $spec;

    # Valid 5-field cron expression — store verbatim
    return $spec if is_cron_expr($spec);

    # Already YYYY-MM-DD
    return $spec if $spec =~ /^\d{4}-\d{2}-\d{2}$/;

    my $now = time;
    my @lt  = localtime($now);    # (sec, min, hour, mday, mon, year, wday, yday, isdst)

    return strftime('%Y-%m-%d', @lt)                    if lc($spec) eq 'today';
    return strftime('%Y-%m-%d', localtime($now+86400))  if lc($spec) eq 'tomorrow';

    # [+-]Nd / [+-]Nw / [+-]Nm / [+-]Ny / [+-]Nh
    if ($spec =~ /^([+-])(\d+)([dhwmy])$/i) {
        my ($sign, $n, $unit) = ($1, $2, lc $3);
        my $mult = $sign eq '+' ? 1 : -1;
        my @new  = @lt;
        if    ($unit eq 'd') { return strftime('%Y-%m-%d', localtime($now + $mult*$n*86400));    }
        elsif ($unit eq 'h') { return strftime('%Y-%m-%d', localtime($now + $mult*$n*3600));     }
        elsif ($unit eq 'w') { return strftime('%Y-%m-%d', localtime($now + $mult*$n*604800));   }
        elsif ($unit eq 'm') {
            $new[4] += $mult * $n;
            while ($new[4] > 11) { $new[4] -= 12; $new[5]++; }
            while ($new[4] < 0)  { $new[4] += 12; $new[5]--; }
            return strftime('%Y-%m-%d', @new);
        }
        elsif ($unit eq 'y') { $new[5] += $mult * $n; return strftime('%Y-%m-%d', @new); }
    }

    # Nd — set day of month to N (this month)
    if ($spec =~ /^(\d{1,2})d$/i) {
        my @new = @lt;
        $new[3] = $1;
        return strftime('%Y-%m-%d', @new);
    }

    # Nw — set weekday within current week (0=Sun … 6=Sat)
    if ($spec =~ /^([0-6])w$/i) {
        my $diff = $1 - $lt[6];
        $diff += 7 if $diff < 0;
        return strftime('%Y-%m-%d', localtime($now + $diff*86400));
    }

    # dayname / +dayname — next occurrence of that weekday
    if ($spec =~ /^\+?([a-z]+)$/i && exists $DAY_MAP{lc $1}) {
        my $target = $DAY_MAP{lc $1};
        my $t = $now + 86400;
        $t += 86400 while (localtime($t))[6] != $target;
        return strftime('%Y-%m-%d', localtime($t));
    }

    # month name — today's date in that month
    if (exists $MONTH_MAP{lc $spec}) {
        my @new = @lt;
        $new[4] = $MONTH_MAP{lc $spec};
        return strftime('%Y-%m-%d', @new);
    }

    # Fallback: only accept a cron expression; anything else is invalid
    return $spec if is_cron_expr($spec);
    warn "tdone: unrecognised timespec '$spec' ignored\n";
    return '';
}

sub parse_opts {
    my ($optstring, $args_ref) = @_;
    my %opts;
    local @ARGV = @$args_ref;
    getopts($optstring, \%opts) or die "Invalid option(s)\n";
    @$args_ref = @ARGV;
    return %opts;
}

# Extract all occurrences of -FLAG VALUE from args, returning the values.
# Modifies @$args_ref in place (removes the -FLAG VALUE pairs).
sub collect_flags {
    my ($flag, $args_ref) = @_;
    my @values;
    my @remaining;
    my $i = 0;
    while ($i < @$args_ref) {
        if ($args_ref->[$i] eq "-$flag" && $i + 1 < @$args_ref) {
            push @values, $args_ref->[++$i];
        } else {
            push @remaining, $args_ref->[$i];
        }
        $i++;
    }
    @$args_ref = @remaining;
    return @values;
}

# ============================================================
# TASK MATCHING AND SORTING
# ============================================================

sub match_todos {
    my ($query, @todos) = @_;
    return @todos unless $query;
    if ($query =~ /^\d+$/) {
        return grep { ($_->{id} // 0) == $query } @todos;
    }
    my $lq = lc $query;
    return grep {
        index(lc($_->{title}   // ''), $lq) >= 0 ||
        index(lc($_->{project} // ''), $lq) >= 0 ||
        index(lc($_->{tags}    // ''), $lq) >= 0
    } @todos;
}

sub todo_sort_key {
    my ($t) = @_;
    my $far   = '9999-12-31';
    my $_eff_date = sub {
        my ($d) = @_;
        return $far unless $d;
        return $d if $d =~ /^\d{4}/;
        if (is_cron_expr($d)) {
            my $next = next_cron_occurrence($d);
            return defined $next ? strftime('%Y-%m-%d', localtime($next)) : $far;
        }
        return $far;
    };
    my $due   = $_eff_date->($t->{due});
    my $sched = $_eff_date->($t->{scheduled});
    # Effective date is the earlier of due/scheduled.
    # When both fall on the same date, due takes priority (tie=0) over scheduled (tie=1).
    my $eff = $due lt $sched ? $due : $sched;
    my $tie = $due le $sched ? 0 : 1;
    return "$eff\t$tie\t" . sprintf('%010d', $t->{id} // 0);
}

sub sort_todos { sort { todo_sort_key($a) cmp todo_sort_key($b) } @_ }

# ============================================================
# DISPLAY HELPERS
# ============================================================

sub display_status {
    my ($t, $todos_by_id) = @_;
    if ($t->{blocked_by}) {
        my @ids = grep { /\S/ } split(/\s+/, $t->{blocked_by});
        if (@ids) {
            if ($todos_by_id) {
                # Blocked if ANY blocking todo is not yet done
                my $still_blocked = grep {
                    my $bt = $todos_by_id->{$_};
                    !$bt || ($bt->{status} // '') ne 'done'
                } @ids;
                return '[=]' if $still_blocked;
            } else {
                return '[=]';
            }
        }
    }
    my $s = $t->{status} // 'todo';
    return '[X]' if $s eq 'done';
    return '[~]' if $s eq 'waiting';
    # Repeating todo (cron timespec in scheduled or due)
    return '[*]' if is_cron_expr($t->{scheduled}) || is_cron_expr($t->{due});
    return '[ ]';
}

# Given a cron field string and allowed range [$min..$max], return sorted list
# of matching integer values.
sub expand_cron_field {
    my ($field, $min, $max) = @_;
    my @vals;
    for my $part (split /,/, $field) {
        if ($part eq '*') {
            push @vals, $min .. $max;
        } elsif ($part =~ /^\*\/(\d+)$/) {
            my $step = $1;
            push @vals, grep { ($_ - $min) % $step == 0 } $min .. $max;
        } elsif ($part =~ /^(\d+)-(\d+)\/(\d+)$/) {
            my ($s, $e, $st) = ($1, $2, $3);
            push @vals, grep { ($_ - $s) % $st == 0 } $s .. $e;
        } elsif ($part =~ /^(\d+)-(\d+)$/) {
            push @vals, $1 .. $2;
        } elsif ($part =~ /^\d+$/) {
            push @vals, int($part);
        }
    }
    my %seen;
    return sort { $a <=> $b } grep { !$seen{$_}++ && $_ >= $min && $_ <= $max } @vals;
}

# Return the epoch of the next occurrence of a 5-field cron expression
# after $from_epoch (defaults to now).  Returns undef if none found in 2 years.
sub next_cron_occurrence {
    my ($expr, $from_epoch) = @_;
    $from_epoch //= time;
    my ($min_f, $hour_f, $mday_f, $mon_f, $wday_f) = split /\s+/, $expr;
    my @mins  = expand_cron_field($min_f,  0, 59);
    my @hours = expand_cron_field($hour_f, 0, 23);
    my @mdays = expand_cron_field($mday_f, 1, 31);
    my @mons  = expand_cron_field($mon_f,  1, 12);
    my @wdays = expand_cron_field($wday_f, 0, 6);
    my $mday_star = ($mday_f eq '*');
    my $wday_star = ($wday_f eq '*');
    my $limit = $from_epoch + 2 * 366 * 86400;
    # Start at the next minute boundary
    my $t = int($from_epoch / 60) * 60 + 60;
    while ($t <= $limit) {
        my @lt = localtime($t);
        my ($lmin, $lhour, $lmday, $lmon0, $lwday) = @lt[1,2,3,4,6];
        my $lmon = $lmon0 + 1;
        # Check month
        unless (grep { $_ == $lmon } @mons) {
            # Advance to 1st of next month at 00:00
            my @nx = @lt;
            $nx[1] = 0; $nx[2] = 0; $nx[3] = 1; $nx[4]++;
            if ($nx[4] > 11) { $nx[4] = 0; $nx[5]++; }
            $t = mktime(@nx);
            next;
        }
        # Check day
        my $day_ok;
        if ($mday_star && $wday_star) {
            $day_ok = 1;
        } elsif ($mday_star) {
            $day_ok = grep { $_ == $lwday } @wdays;
        } elsif ($wday_star) {
            $day_ok = grep { $_ == $lmday } @mdays;
        } else {
            $day_ok = (grep { $_ == $lmday } @mdays) || (grep { $_ == $lwday } @wdays);
        }
        unless ($day_ok) {
            # Advance to next midnight
            my @nx = @lt;
            $nx[0] = 0; $nx[1] = 0; $nx[2] = 0; $nx[3]++;
            $t = mktime(@nx);
            next;
        }
        # Check hour
        unless (grep { $_ == $lhour } @hours) {
            # Advance to next hour boundary
            my @nx = @lt;
            $nx[0] = 0; $nx[1] = 0; $nx[2]++;
            $t = mktime(@nx);
            next;
        }
        # Check minute
        unless (grep { $_ == $lmin } @mins) {
            $t += 60;
            next;
        }
        return $t;
    }
    return undef;
}

sub fmt_date {
    my ($d) = @_;
    return '' unless $d;
    if (is_cron_expr($d)) {
        my $next = next_cron_occurrence($d);
        return defined $next ? strftime('%Y-%m-%d', localtime($next)) : $d;
    }
    return $d;
}

sub table_layout {
    my ($terminal_cols) = @_;
    my $fixed   = $W_ID + $W_STATUS + $W_PROJECT + $W_SCHED + $W_DUE + $W_PRI + $W_TAGS + 9;
    my $title_w = max(10, $terminal_cols - $fixed);
    my $hdr = sprintf "%-${W_ID}s %-${W_STATUS}s %-${W_PROJECT}s %-*s %-${W_SCHED}s %-${W_DUE}s %-${W_PRI}s %s",
        @TABLE_HEADERS[0,1,2], $title_w, @TABLE_HEADERS[3..7];
    my $row_fmt = "%-${W_ID}s %-${W_STATUS}s %-${W_PROJECT}s %-*s"
                . " %-${W_SCHED}.${W_SCHED}s %-${W_DUE}.${W_DUE}s %-${W_PRI}s %-${W_TAGS}s%s\n";
    return ($title_w, $hdr, $row_fmt);
}

sub print_table {
    my @todos = @_;
    my $cols = 80;
    eval { ($cols) = GetTerminalSize() };
    my %by_id = map { $_->{id} => $_ } load_todos();
    my ($title_w, $hdr, $row_fmt) = table_layout($cols);
    print $hdr, "\n";
    print '-' x $cols, "\n";
    for my $t (@todos) {
        my $desc_star = $t->{description} ? '*' : ' ';
        printf $row_fmt,
            $t->{id} // '',
            substr(display_status($t, \%by_id), 0, $W_STATUS),
            substr($t->{project} // '', 0, $W_PROJECT),
            $title_w, substr($t->{title} // '', 0, $title_w),
            fmt_date($t->{scheduled}),
            fmt_date($t->{due}),
            substr($t->{priority} // '', 0, $W_PRI),
            substr($t->{tags} // '', 0, $W_TAGS),
            $desc_star;
    }
}

# ============================================================
# YAML EDIT
# ============================================================

sub todo_to_yaml_hash {
    my ($t) = @_;
    return {
        title       => $t->{title}       // '',
        status      => $t->{status}      // 'todo',
        project     => $t->{project}     // '',
        scheduled   => $t->{scheduled}   // '',
        due         => $t->{due}         // '',
        priority    => $t->{priority}    // '',
        tags        => $t->{tags}        // '',
        blocked_by  => $t->{blocked_by}  // '',
        description => $t->{description} // '',
    };
}

sub edit_todo_yaml {
    my ($t) = @_;
    my $editor = $ENV{VISUAL} || $ENV{EDITOR} || 'vi';
    my (undef, $fname) = tempfile(SUFFIX => '.yaml', UNLINK => 0);
    my $yaml = YAML::Tiny->new(todo_to_yaml_hash($t));
    my $yaml_str = $yaml->write_string
        or die 'YAML serialization error: ' . YAML::Tiny->errstr . "\n";
    path($fname)->spew_utf8($yaml_str);
    system($editor, $fname);
    my $content = path($fname)->slurp_utf8;
    path($fname)->remove;
    my $data = YAML::Tiny->read_string($content)
        or die 'YAML parse error: ' . YAML::Tiny->errstr . "\n";
    my $h = $data->[0] // {};
    for my $f (qw(title status project scheduled due priority tags blocked_by description)) {
        $t->{$f} = $h->{$f} // '';
    }
    return $t;
}

# ============================================================
# PARSE TASK STRING  (+tag  ^project  title words)
# ============================================================

sub parse_todo_string {
    my ($str) = @_;
    my (@tags, $project, @words);
    for my $w (split /\s+/, $str) {
        if    ($w =~ /^\+(.+)$/) { push @tags, $1; }
        elsif ($w =~ /^\^(.+)$/) { $project = $1; }
        else                     { push @words, $w; }
    }
    return (
        title   => join(' ', @words),
        project => $project // '',
        tags    => join(' ', @tags),
    );
}

# ============================================================
# COMMANDS
# ============================================================

sub cmd_add {
    my @args = @_;
    my %opts = parse_opts('et:', \@args);
    my ($opt_e, $opt_t) = ($opts{e}, $opts{t});
    my $str = join(' ', @args);

    my %fields = parse_todo_string($str);
    my @todos  = load_todos();
    my %todo   = (
        id          => next_id(@todos),
        status      => 'todo',
        project     => $fields{project},
        title       => $fields{title},
        scheduled   => '',
        due         => defined $opt_t ? parse_timespec($opt_t) : '',
        priority    => '',
        blocked_by  => '',
        tags        => $fields{tags},
        description => '',
    );
    edit_todo_yaml(\%todo) if $opt_e;
    push @todos, \%todo;
    save_todos(@todos);
    printf "Added todo %d: %s\n", $todo{id}, $todo{title};
}

sub cmd_schedule {
    my @args = @_;
    my %opts = parse_opts('t:', \@args);
    my $opt_t = $opts{t};
    my $query = join(' ', @args);
    my $date  = defined $opt_t ? parse_timespec($opt_t) : strftime('%Y-%m-%d', localtime);
    my @todos = load_todos();
    my $n = 0;
    for my $t (@todos) {
        next unless match_todos($query, $t);
        $t->{scheduled} = $date;
        $n++;
    }
    save_todos(@todos);
    printf "Scheduled %d todo(s) for %s\n", $n, $date;
}

sub cmd_due {
    my @args = @_;
    my %opts = parse_opts('t:', \@args);
    my $opt_t = $opts{t};
    my $query = join(' ', @args);
    my $date  = defined $opt_t ? parse_timespec($opt_t) : strftime('%Y-%m-%d', localtime);
    my @todos = load_todos();
    my $n = 0;
    for my $t (@todos) {
        next unless match_todos($query, $t);
        $t->{due} = $date;
        $n++;
    }
    save_todos(@todos);
    printf "Set due date of %d todo(s) to %s\n", $n, $date;
}

sub cmd_block {
    my @args  = @_;
    my %opts  = parse_opts('i:', \@args);
    my $id    = $opts{i} // die "Usage: block -i <id> <query>\n";
    my $query = join(' ', @args);
    $query or die "Usage: block -i <id> <query>\n";
    my @todos   = load_todos();
    my @blockers = match_todos($query, @todos);
    return print "No todos matching '$query'\n" unless @blockers;
    my %blocker_ids = map { $_->{id} => 1 } @blockers;
    my $n = 0;
    for my $t (@todos) {
        next unless ($t->{id} // 0) == $id;
        my @existing = grep { /\S/ } split(/\s+/, $t->{blocked_by} // '');
        my %seen = map { $_ => 1 } @existing;
        my @new_blockers = grep { !$seen{$_} } sort keys %blocker_ids;
        $t->{blocked_by} = join(' ', @existing, @new_blockers);
        $n++;
    }
    save_todos(@todos);
    printf "Todo %s is now blocked by %d todo(s)\n", $id, scalar keys %blocker_ids;
}

sub get_list_todos {
    my @args = @_;
    my @filter_tags     = collect_flags('x', \@args);
    my @filter_projects = collect_flags('p', \@args);
    my %opts = parse_opts('adA:B:', \@args);
    my ($opt_a, $opt_d, $opt_A, $opt_B) = ($opts{a}, $opts{d}, $opts{A}, $opts{B});
    my $query = join(' ', @args);
    my @todos = load_todos();
    my @show;
    if ($opt_d) {
        @show = grep { ($_->{status} // '') eq 'done' } @todos;
    } elsif ($opt_a) {
        @show = @todos;
    } else {
        @show = grep { ($_->{status} // '') ne 'done' } @todos;
    }
    if (defined $opt_A) {
        my $today = strftime('%Y-%m-%d', localtime);
        my $ahead = strftime('%Y-%m-%d', localtime(time + $opt_A * 86400));
        @show = grep {
            my $sched = $_->{scheduled} // '';
            my $due   = $_->{due}       // '';
            ($sched =~ /^\d{4}/ && $sched ge $today && $sched le $ahead) ||
            ($due   =~ /^\d{4}/ && $due   ge $today && $due   le $ahead)
        } @show;
    }
    if (defined $opt_B) {
        my $today  = strftime('%Y-%m-%d', localtime);
        my $before = strftime('%Y-%m-%d', localtime(time - $opt_B * 86400));
        @show = grep {
            my $sched = $_->{scheduled} // '';
            my $due   = $_->{due}       // '';
            ($sched =~ /^\d{4}/ && $sched le $today && $sched ge $before) ||
            ($due   =~ /^\d{4}/ && $due   le $today && $due   ge $before)
        } @show;
    }
    # -x <tag> filters (AND): all specified tags must be present
    for my $tag (@filter_tags) {
        my $tl = lc $tag;
        @show = grep {
            my %todo_tags = map { lc($_) => 1 } split(/\s+/, $_->{tags} // '');
            exists $todo_tags{$tl}
        } @show;
    }
    # -p <project> filters (OR): todo must belong to one of the specified projects
    if (@filter_projects) {
        my %proj_set = map { lc($_) => 1 } @filter_projects;
        @show = grep { $proj_set{lc($_->{project} // '')} } @show;
    }
    # Text query searches title and description only
    if ($query) {
        if ($query =~ /^\d+$/) {
            @show = grep { ($_->{id} // 0) == $query } @show;
        } else {
            my $lq = lc $query;
            @show = grep {
                index(lc($_->{title}       // ''), $lq) >= 0 ||
                index(lc($_->{description} // ''), $lq) >= 0
            } @show;
        }
    }
    return sort_todos(@show);
}

sub cmd_list {
    print_table(get_list_todos(@_));
}

sub cmd_kill {
    my $query = join(' ', @_);
    my @todos   = load_todos();
    my @removed = match_todos($query, @todos);
    return print "No matching todos\n" unless @removed;
    my %rm = map { $_->{id} => 1 } @removed;
    save_todos(grep { !$rm{$_->{id}} } @todos);
    printf "Deleted %d todo(s)\n", scalar @removed;
}

sub cmd_done {
    my @args = @_;
    my %opts = parse_opts('r', \@args);
    my $query = join(' ', @args);
    my $new_status = $opts{r} ? 'todo' : 'done';
    my @todos = load_todos();
    my $n = 0;
    for my $t (@todos) {
        next unless match_todos($query, $t);
        $t->{status} = $new_status;
        $n++;
    }
    save_todos(@todos);
    printf $opts{r} ? "Reopened %d todo(s)\n" : "Marked %d todo(s) done\n", $n;
}

sub cmd_waiting {
    my $query = join(' ', @_);
    my @todos = load_todos();
    my $n = 0;
    for my $t (@todos) {
        next unless match_todos($query, $t);
        $t->{status} = 'waiting';
        $n++;
    }
    save_todos(@todos);
    printf "Marked %d todo(s) waiting\n", $n;
}

sub cmd_edit {
    my $query = join(' ', @_);
    my @todos = load_todos();
    my $n = 0;
    for my $t (@todos) {
        next unless match_todos($query, $t);
        edit_todo_yaml($t);
        $n++;
    }
    save_todos(@todos) if $n;
    printf "Edited %d todo(s)\n", $n;
}

sub cmd_modify {
    my @args        = @_;
    my @new_tags    = collect_flags('x', \@args);
    my @remove_tags = collect_flags('X', \@args);
    my @projects    = collect_flags('p', \@args);
    my $project     = @projects ? $projects[-1] : undef;
    die "Usage: modify <query> [-x <tag>]... [-X <tag>]... [-p <project>]\n"
        unless @new_tags || @remove_tags || defined $project;
    my $query = join(' ', @args);
    my @todos = load_todos();
    my $n = 0;
    for my $t (@todos) {
        next unless match_todos($query, $t);
        for my $tag (@new_tags) {
            my @existing = split(/\s+/, $t->{tags} // '');
            unless (grep { $_ eq $tag } @existing) {
                $t->{tags} = join(' ', @existing, $tag);
            }
        }
        for my $tag (@remove_tags) {
            my @existing = split(/\s+/, $t->{tags} // '');
            $t->{tags} = join(' ', grep { $_ ne $tag } @existing);
        }
        $t->{project} = $project if defined $project;
        $n++;
    }
    save_todos(@todos);
    printf "Modified %d todo(s)\n", $n;
}

# ============================================================
# COMMAND DISPATCH
# ============================================================

our %CMD = (
    add      => \&cmd_add,
    schedule => \&cmd_schedule,
    due      => \&cmd_due,
    block    => \&cmd_block,
    list     => \&cmd_list,
    ls       => \&cmd_list,     # alias — excluded from prefix matching
    kill     => \&cmd_kill,
    x        => \&cmd_done,
    waiting  => \&cmd_waiting,
    edit     => \&cmd_edit,
    modify   => \&cmd_modify,
);

# Commands that are pure aliases; they match exactly but are not used for
# prefix expansion so that e.g. 'l' unambiguously expands to 'list'.
our %ALIASES = (ls => 1);

sub dispatch_command {
    my @args = @_;
    return unless @args;
    my $verb = lc shift @args;

    # Exact match first (including aliases like 'ls')
    if (exists $CMD{$verb}) {
        $CMD{$verb}->(@args);
        return;
    }

    # Prefix matching against non-alias commands only
    my @matches = grep { !$ALIASES{$_} && /^\Q$verb\E/i } keys %CMD;

    if (@matches == 1) {
        $CMD{$matches[0]}->(@args);
        return;
    }
    if (@matches > 1) {
        die "Ambiguous command '$verb': " . join(', ', sort @matches) . "\n";
    }
    die "Unknown command: $verb\nTry: " . join(', ', sort keys %CMD) . "\n";
}

# ============================================================
# MAIN ENTRY POINT
# ============================================================

sub run {
    my @args = @_;
    if (@args) {
        dispatch_command(@args);
    } else {
        cmd_list();
    }
}

1;
