package TDone;
use strict;
use warnings;
use utf8;
use POSIX         qw(strftime mktime);
use File::Temp    qw(tempfile);
use Path::Tiny;
use List::Util    qw(max);
use Getopt::Std   qw(getopts);
use YAML::Tiny;
use Term::ReadKey;

our $VERSION = '0.1.0';

# ============================================================
# DATA FILE
# ============================================================

my @FIELDS = qw(id status project title scheduled due priority blocked_by tags description);

sub data_file {
    return $ENV{TDONE_FILE} if defined $ENV{TDONE_FILE} && $ENV{TDONE_FILE} ne '';
    my $dir = "$ENV{HOME}/.tdone";
    path($dir)->mkpath unless -d $dir;
    return "$dir/todos.tsv";
}

sub load_tasks {
    my $file = data_file();
    return () unless -f $file;
    my @tasks;
    for (path($file)->lines_utf8({chomp => 1})) {
        next if /^\s*$/;
        my @vals = split /\t/, $_, scalar @FIELDS;
        push @vals, '' while @vals < scalar @FIELDS;
        my %t;
        @t{@FIELDS} = @vals;
        $t{description} =~ s/\\n/\n/g;
        push @tasks, \%t;
    }
    return @tasks;
}

sub save_tasks {
    my @tasks = @_;
    my $file = data_file();
    my @lines;
    for my $t (@tasks) {
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
    my @tasks = @_;
    my $max = 0;
    $max < ($_ // 0) and $max = $_ for map { $_->{id} } @tasks;
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
    return 0 unless defined $s && $s ne '';
    return $s =~ /^[\d\*\/,\-]+(?:\s+[\d\*\/,\-]+){4}$/;
}

sub parse_timespec {
    my ($spec) = @_;
    return '' unless defined $spec && $spec ne '';

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

# ============================================================
# TASK MATCHING AND SORTING
# ============================================================

sub match_todos {
    my ($query, @todos) = @_;
    return @todos unless defined $query && $query ne '';
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
    my $due   = ($t->{due}       // '') =~ /^\d{4}/ ? $t->{due}       : $far;
    my $sched = ($t->{scheduled} // '') =~ /^\d{4}/ ? $t->{scheduled} : $far;
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
    my ($t) = @_;
    return '[=]' if ($t->{blocked_by} // '') ne '';
    my $s = $t->{status} // 'todo';
    return '[X]' if $s eq 'done';
    return '[~]' if $s eq 'waiting';
    return '[ ]';
}

sub fmt_date {
    my ($d) = @_;
    return '' unless defined $d && $d ne '';
    return $d;    # YYYY-MM-DD or cron expression — return as-is
}

sub print_table {
    my @todos = @_;
    my $cols = 80;
    eval { ($cols) = GetTerminalSize() };
    my $title_w = max(10, $cols - 85);
    printf "%-4s %-9s %-12s %-*s %-14s %-14s %-4s %s\n",
        'ID', 'STATUS', 'PROJECT', $title_w, 'TITLE',
        'SCHEDULED', 'DUE', 'PRI', 'TAGS';
    print '-' x $cols, "\n";
    for my $t (@todos) {
        my $desc_star = ($t->{description} // '') ne '' ? '*' : ' ';
        printf "%-4s %-9s %-12s %-*s %-14.14s %-14.14s %-4s %-20s%s\n",
            $t->{id} // '',
            substr(display_status($t), 0, 9),
            substr($t->{project} // '', 0, 12),
            $title_w, substr($t->{title} // '', 0, $title_w),
            fmt_date($t->{scheduled}),
            fmt_date($t->{due}),
            substr($t->{priority} // '', 0, 4),
            substr($t->{tags} // '', 0, 20),
            $desc_star;
    }
}

# ============================================================
# YAML EDIT
# ============================================================

sub task_to_yaml_hash {
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

sub edit_task_yaml {
    my ($t) = @_;
    my $editor = $ENV{VISUAL} || $ENV{EDITOR} || 'vi';
    my $yaml   = YAML::Tiny->new(task_to_yaml_hash($t));
    my ($fh, $fname) = tempfile(SUFFIX => '.yaml', UNLINK => 0);
    print $fh $yaml->write_string;
    close $fh;
    system($editor, $fname);
    open my $rfh, '<:encoding(UTF-8)', $fname
        or die "Cannot read $fname: $!\n";
    my $content = do { local $/; <$rfh> };
    close $rfh;
    unlink $fname;
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
    my @todos  = load_tasks();
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
    edit_task_yaml(\%todo) if $opt_e;
    push @todos, \%todo;
    save_tasks(@todos);
    printf "Added todo %d: %s\n", $todo{id}, $todo{title};
}

sub cmd_schedule {
    my @args = @_;
    my %opts = parse_opts('t:', \@args);
    my $opt_t = $opts{t};
    my $query = join(' ', @args);
    my $date  = defined $opt_t ? parse_timespec($opt_t) : strftime('%Y-%m-%d', localtime);
    my @todos = load_tasks();
    my $n = 0;
    for my $t (@todos) {
        next unless match_todos($query, $t);
        $t->{scheduled} = $date;
        $n++;
    }
    save_tasks(@todos);
    printf "Scheduled %d todo(s) for %s\n", $n, $date;
}

sub cmd_due {
    my @args = @_;
    my %opts = parse_opts('t:', \@args);
    my $opt_t = $opts{t};
    my $query = join(' ', @args);
    my $date  = defined $opt_t ? parse_timespec($opt_t) : strftime('%Y-%m-%d', localtime);
    my @todos = load_tasks();
    my $n = 0;
    for my $t (@todos) {
        next unless match_todos($query, $t);
        $t->{due} = $date;
        $n++;
    }
    save_tasks(@todos);
    printf "Set due date of %d todo(s) to %s\n", $n, $date;
}

sub cmd_block {
    my @args  = @_;
    my $id    = shift @args;
    defined $id or die "Usage: block <id> <query>\n";
    my $query = join(' ', @args);
    $query ne '' or die "Usage: block <id> <query>\n";
    my @todos = load_tasks();
    my $n = 0;
    for my $t (@todos) {
        next unless match_todos($query, $t);
        $t->{blocked_by} = $id;
        $n++;
    }
    save_tasks(@todos);
    printf "Blocked %d todo(s) by todo %s\n", $n, $id;
}

sub cmd_list {
    my @args = @_;
    my %opts = parse_opts('adA:B:', \@args);
    my ($opt_a, $opt_d, $opt_A, $opt_B) = ($opts{a}, $opts{d}, $opts{A}, $opts{B});
    my $query = join(' ', @args);
    my @todos = load_tasks();
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
    @show = match_todos($query, @show) if $query ne '';
    print_table(sort_todos(@show));
}

sub cmd_kill {
    my $query = join(' ', @_);
    my @todos   = load_tasks();
    my @removed = match_todos($query, @todos);
    return print "No matching todos\n" unless @removed;
    my %rm = map { $_->{id} => 1 } @removed;
    save_tasks(grep { !$rm{$_->{id}} } @todos);
    printf "Deleted %d todo(s)\n", scalar @removed;
}

sub cmd_complete {
    my $query = join(' ', @_);
    my @todos = load_tasks();
    my $n = 0;
    for my $t (@todos) {
        next unless match_todos($query, $t);
        $t->{status} = 'done';
        $n++;
    }
    save_tasks(@todos);
    printf "Marked %d todo(s) done\n", $n;
}

sub cmd_waiting {
    my $query = join(' ', @_);
    my @todos = load_tasks();
    my $n = 0;
    for my $t (@todos) {
        next unless match_todos($query, $t);
        $t->{status} = 'waiting';
        $n++;
    }
    save_tasks(@todos);
    printf "Marked %d todo(s) waiting\n", $n;
}

sub cmd_edit {
    my $query = join(' ', @_);
    my @todos = load_tasks();
    my $n = 0;
    for my $t (@todos) {
        next unless match_todos($query, $t);
        edit_task_yaml($t);
        $n++;
    }
    save_tasks(@todos) if $n;
    printf "Edited %d todo(s)\n", $n;
}

sub cmd_tag {
    my @args = @_;
    my %opts = parse_opts('x:', \@args);
    my $tag   = $opts{x} // die "Usage: tag -x <tagname> [query]\n";
    my $query = join(' ', @args);
    my @todos = load_tasks();
    my $n = 0;
    for my $t (@todos) {
        next unless match_todos($query, $t);
        my @existing = split(/\s+/, $t->{tags} // '');
        unless (grep { $_ eq $tag } @existing) {
            $t->{tags} = join(' ', @existing, $tag);
            $n++;
        }
    }
    save_tasks(@todos);
    printf "Tagged %d todo(s) with +%s\n", $n, $tag;
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
    complete => \&cmd_complete,
    waiting  => \&cmd_waiting,
    edit     => \&cmd_edit,
    tag      => \&cmd_tag,
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
