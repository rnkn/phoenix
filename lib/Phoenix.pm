package Phoenix;
use strict;
use warnings;
use open qw(:std :utf8);
use Exporter qw(import);
use POSIX qw(strftime mktime);
use File::Temp qw(tempfile);
use Path::Tiny;
use List::Util qw(max);
use YAML::Tiny;
use Term::ReadKey;

our $VERSION = '0.1.0';
our @EXPORT_OK = qw($W_ID $W_STATUS $W_PROJECT $W_SCHED $W_DUE $W_PRI $W_TAGS @TABLE_HEADERS fmt_priority is_urgent);

use constant {
	BOLD  => "\033[1m",
	RESET => "\033[0m",
};

# ============================================================
# DATA FILE
# ============================================================

my @FIELDS = qw(id status project title scheduled due priority blocked_by tags description);

our $W_ID	   =  4;
our $W_STATUS  =  4;
our $W_PROJECT = 14;
our $W_SCHED   = 12;
our $W_DUE	   = 12;
our $W_PRI	   =  4;
our $W_TAGS	   = 30;
our @TABLE_HEADERS = ('id', '[ ]', 'project', 'title', 'scheduled', 'due', '!!!', 'tags');

sub data_file {
	return $ENV{PHX_FILE} if $ENV{PHX_FILE};
	my $dir = "$ENV{HOME}/.phoenix";
	path($dir)->mkpath unless -d $dir;
	return "$dir/tasks.tsv";
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
			$v =~ s/\t/	   /g;
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
	sunday	  => 0, monday	=> 1, tuesday	=> 2, wednesday => 3,
	thursday  => 4, friday	=> 5, saturday	=> 6,
	sun => 0, mon => 1, tue => 2, wed => 3, thu => 4, fri => 5, sat => 6,
);

my %MONTH_MAP = (
	january	  => 0, february => 1, march	=> 2, april	   => 3,
	may		  => 4, june	 => 5, july		=> 6, august   => 7,
	september => 8, october	 => 9, november => 10, december => 11,
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
	my @lt	= localtime($now);	  # (sec, min, hour, mday, mon, year, wday, yday, isdst)

	return strftime('%Y-%m-%d', @lt)					if lc($spec) eq 'today';
	return strftime('%Y-%m-%d', localtime($now+86400))	if lc($spec) eq 'tomorrow';

	# [+-]Nd / [+-]Nw / [+-]Nm / [+-]Ny / [+-]Nh
	if ($spec =~ /^([+-])(\d+)([dhwmy])$/i) {
		my ($sign, $n, $unit) = ($1, $2, lc $3);
		my $mult = $sign eq '+' ? 1 : -1;
		my @new	 = @lt;
		if	  ($unit eq 'd') { return strftime('%Y-%m-%d', localtime($now + $mult*$n*86400));	 }
		elsif ($unit eq 'h') { return strftime('%Y-%m-%d', localtime($now + $mult*$n*3600));	 }
		elsif ($unit eq 'w') { return strftime('%Y-%m-%d', localtime($now + $mult*$n*604800));	 }
		elsif ($unit eq 'm') {
			$new[4] += $mult * $n;
			while ($new[4] > 11) { $new[4] -= 12; $new[5]++; }
			while ($new[4] < 0)	 { $new[4] += 12; $new[5]--; }
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
	warn "phx: unrecognised timespec '$spec' ignored\n";
	return '';
}

sub parse_opts_raw {
	my ($optstring, $args_ref) = @_;
	my %takes_value;
	while ($optstring =~ /([a-zA-Z])(:?)/g) {
		$takes_value{$1} = ($2 eq ':');
	}
	my %opts;
	my @remaining;
	my $i = 0;
	while ($i < @$args_ref) {
		my $arg = $args_ref->[$i];
		if ($arg =~ /^-([a-zA-Z])$/) {
			my $flag = $1;
			die "Unknown option: -$flag\n" unless exists $takes_value{$flag};
			if ($takes_value{$flag}) {
				die "Option -$flag requires a value\n" unless $i + 1 < @$args_ref;
				push @{$opts{$flag}}, $args_ref->[++$i];
			} else {
				$opts{$flag} = 1;
			}
		} else {
			push @remaining, $arg;
		}
		$i++;
	}
	@$args_ref = @remaining;
	return %opts;
}

sub parse_opts {
	my ($optstring, $args_ref, $usage) = @_;
	my %opts = eval { parse_opts_raw($optstring, $args_ref) };
	die $usage if $@;
	return %opts;
}

# ============================================================
# TASK MATCHING AND SORTING
# ============================================================

sub match_tasks {
	my ($query, @tasks) = @_;
	return @tasks unless $query;
	if ($query =~ /^\d+$/) {
		return grep { ($_->{id} // 0) == $query } @tasks;
	}
	my $lq = lc $query;
	return grep {
		index(lc($_->{title}   // ''), $lq) >= 0 ||
		index(lc($_->{description} // ''), $lq) >= 0
	} @tasks;
}

sub task_sort_key {
	my ($t) = @_;
	my $far	  = '9999-12-31';
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
	my $due	  = $_eff_date->($t->{due});
	my $sched = $_eff_date->($t->{scheduled});
	# Effective date is the earlier of due/scheduled.
	# When both fall on the same date, due takes priority (tie=0) over scheduled (tie=1).
	my $eff = $due lt $sched ? $due : $sched;
	my $tie = $due le $sched ? 0 : 1;
	return "$eff\t$tie\t" . sprintf('%010d', $t->{id} // 0);
}

sub sort_tasks { sort { task_sort_key($a) cmp task_sort_key($b) } @_ }

# ============================================================
# DISPLAY HELPERS
# ============================================================

sub display_status {
	my ($t, $tasks_by_id) = @_;
	if ($t->{blocked_by}) {
		my @ids = grep { /\S/ } split(/\s+/, $t->{blocked_by});
		if (@ids) {
			if ($tasks_by_id) {
				# Blocked if ANY blocking task is not yet done
				my $still_blocked = grep {
					my $bt = $tasks_by_id->{$_};
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
	# Repeating task (cron timespec in scheduled or due)
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
# after $from_epoch (defaults to now).	Returns undef if none found in 2 years.
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

sub fmt_priority {
	my ($p) = @_;
	return '' unless $p && $p =~ /^\d+$/;
	my $n = $p > 3 ? 3 : $p;
	return '!' x $n;
}

sub is_urgent {
	my ($t) = @_;
	my $today = strftime('%Y-%m-%d', localtime);
	for my $field (qw(due scheduled)) {
		my $d = fmt_date($t->{$field});
		return 1 if $d && $d =~ /^\d{4}-\d{2}-\d{2}$/ && $d le $today;
	}
	return 0;
}

sub table_layout {
	my ($terminal_cols) = @_;
	my $fixed	= $W_ID + $W_STATUS + $W_PROJECT + $W_SCHED + $W_DUE + $W_PRI + $W_TAGS + 8;
	my $title_w = max(10, $terminal_cols - $fixed);
	my $hdr = sprintf "%-${W_ID}s %-${W_STATUS}s %-${W_PROJECT}s %-*s %-${W_SCHED}s %-${W_DUE}s %-${W_PRI}s %s",
		@TABLE_HEADERS[0,1,2], $title_w, @TABLE_HEADERS[3..7];
	my $row_fmt = "%-${W_ID}s %-${W_STATUS}s %-${W_PROJECT}s %-*s"
				. " %-${W_SCHED}.${W_SCHED}s %-${W_DUE}.${W_DUE}s %-${W_PRI}s %-${W_TAGS}s%s\n";
	return ($title_w, $hdr, $row_fmt);
}

sub print_table {
	my @tasks = @_;
	my $cols = 80;
	eval { ($cols) = GetTerminalSize() };
	my %by_id = map { $_->{id} => $_ } load_tasks();
	my ($title_w, $hdr, $row_fmt) = table_layout($cols);
	print $hdr, "\n";
	print "\x{2500}" x $cols, "\n";
	for my $t (@tasks) {
		my $desc_star = $t->{description} ? '*' : ' ';
		my $urgent = is_urgent($t);
		print BOLD if $urgent;
		printf $row_fmt,
			$t->{id} // '',
			substr(display_status($t, \%by_id), 0, $W_STATUS),
			substr($t->{project} // '', 0, $W_PROJECT),
			$title_w, substr($t->{title} // '', 0, $title_w),
			fmt_date($t->{scheduled}),
			fmt_date($t->{due}),
			substr(fmt_priority($t->{priority}), 0, $W_PRI),
			substr($t->{tags} // '', 0, $W_TAGS),
			$desc_star;
		print RESET if $urgent;
	}
}

# ============================================================
# YAML EDIT
# ============================================================

sub task_to_yaml_hash {
	my ($t) = @_;
	return {
		title		=> $t->{title}		 // '',
		status		=> $t->{status}		 // 'todo',
		project		=> $t->{project}	 // '',
		scheduled	=> $t->{scheduled}	 // '',
		due			=> $t->{due}		 // '',
		priority	=> $t->{priority}	 // '',
		tags		=> $t->{tags}		 // '',
		blocked_by	=> $t->{blocked_by}	 // '',
		description => $t->{description} // '',
	};
}

sub edit_task_yaml {
	my ($t) = @_;
	my $editor = $ENV{VISUAL} || $ENV{EDITOR} || 'vi';
	my (undef, $fname) = tempfile(SUFFIX => '.yaml', UNLINK => 0);
	my $yaml = YAML::Tiny->new(task_to_yaml_hash($t));
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
# PARSE TASK STRING	 (+tag	^project  =id  id=  title words)
# ============================================================

sub parse_task_string {
	my ($str) = @_;
	my (@tags, $project, @blocked_by_ids, @blocks_ids, @words);
	for my $w (split /\s+/, $str) {
		if    ($w =~ /^\+(.+)$/)        { push @tags, $1; }
		elsif ($w =~ /^\^(.+)$/)        { $project = $1; }
		elsif ($w =~ /^=([1-9]\d*)$/)  { push @blocked_by_ids, $1; }
		elsif ($w =~ /^([1-9]\d*)=$/)  { push @blocks_ids, $1; }
		else                            { push @words, $w; }
	}
	return (
		title			=> join(' ', @words),
		project			=> $project // '',
		tags			=> join(' ', @tags),
		blocked_by_ids	=> \@blocked_by_ids,
		blocks_ids		=> \@blocks_ids,
	);
}

# ============================================================
# COMMANDS
# ============================================================

sub cmd_add {
	my $usage = 'Usage: add [-e] [-d <timespec>] [-s <timespec>] [-w] [-m <description>] [-p <project>] [-t <tag>]... [-b <task_id>]... [-B <task_id>]... [-0|-1|-2|-3] [!,!!,!!!] [^<project>] [+<tag>]... [=<task_id>]... [<task_id>=]... <title>';
	my @args = @_;

	# Extract numeric priority flags (-0, -1, -2, -3) before parse_opts
	my $flag_priority = undef;
	my @filtered_args;
	for my $arg (@args) {
		if    ($arg eq '-0') { $flag_priority = '';  }
		elsif ($arg eq '-1') { $flag_priority = 1;   }
		elsif ($arg eq '-2') { $flag_priority = 2;   }
		elsif ($arg eq '-3') { $flag_priority = 3;   }
		else                 { push @filtered_args, $arg; }
	}
	@args = @filtered_args;

	my %opts = parse_opts('ed:s:wm:p:t:b:B:', \@args, $usage);
	my $opt_e = $opts{e} ? 1 : 0;
	my $opt_d = defined $opts{d} ? parse_timespec($opts{d}[-1]) : '';
	my $opt_s = defined $opts{s} ? parse_timespec($opts{s}[-1]) : '';
	my $opt_w = $opts{w} ? 1 : 0;
	my $opt_m = defined $opts{m} ? $opts{m}[-1] : '';
	my $str = join(' ', @args);
	die $usage unless $str;

	my %fields = parse_task_string($str);
	die $usage unless $fields{title};

	# -p flag overrides ^project inline syntax; -t flag merges with +tag inline syntax
	my $project = $opts{p} ? $opts{p}[-1] : $fields{project};
	my @flag_tags = @{$opts{t} // []};
	my @inline_tags = $fields{tags} ? split(/\s+/, $fields{tags}) : ();
	my %seen_tags;
	my @all_tags = grep { !$seen_tags{$_}++ } (@flag_tags, @inline_tags);

	# Collect blocked_by IDs from -b flag and =<id> inline syntax
	my @blocked_by_ids = (@{$fields{blocked_by_ids}}, @{$opts{b} // []});
	# Collect blocks IDs (tasks to be blocked by new task) from -B flag and <id>= inline syntax
	my @blocks_ids = (@{$fields{blocks_ids}}, @{$opts{B} // []});

	my $priority = '';
	if ($fields{title} =~ s/(?:\s+|^)(!!!|!!|!)(?:\s+|$)/ /) {
		my $bang = $1;
		$priority = length($bang);
		$fields{title} = join(' ', grep { length } split(/\s+/, $fields{title}));
	}
	# -1/-2/-3 flag overrides inline ! syntax
	$priority = $flag_priority if defined $flag_priority;

	my @tasks  = load_tasks();
	my %task   = (
		id			=> next_id(@tasks),
		status		=> $opt_w ? 'waiting' : 'todo',
		project		=> $project,
		title		=> $fields{title},
		scheduled	=> $opt_s,
		due			=> $opt_d,
		priority	=> $priority,
		blocked_by	=> join(' ', @blocked_by_ids),
		tags		=> join(' ', @all_tags),
		description => $opt_m,
	);
	edit_task_yaml(\%task) if $opt_e;
	push @tasks, \%task;

	# Update tasks that should be blocked by the new task
	if (@blocks_ids) {
		my %blocks_set = map { $_ => 1 } @blocks_ids;
		for my $t (@tasks) {
			next unless $blocks_set{$t->{id} // ''};
			my @existing = grep { /\S/ } split(/\s+/, $t->{blocked_by} // '');
			unless (grep { $_ eq $task{id} } @existing) {
				$t->{blocked_by} = join(' ', @existing, $task{id});
			}
		}
	}

	save_tasks(@tasks);
	printf "Added task %d: %s\n", $task{id}, $task{title};
}

sub cmd_schedule {
	# alias for `modify -s <timespace> <query>`
	my $usage = 'Usage: schedule <timespec> <query>';
	my @args = @_;
	die $usage unless @args >= 2;
	my $timespec = shift @args;
	my $query = join(' ', @args);
	die $usage unless $timespec && $query;
	cmd_modify('-s', $timespec, $query);
}

sub cmd_due {
	# alias for `modify -d <timespace> <query>`
	my $usage = 'Usage: due <timespec> <query>';
	my @args = @_;
	die $usage unless @args >= 2;
	my $timespec = shift @args;
	my $query = join(' ', @args);
	die $usage unless $timespec && $query;
	cmd_modify('-d', $timespec, $query);
}

sub cmd_block {
	my $usage = "Usage: block [-r] <blocked-query> [<blocking-query>]\n";
	my @args = @_;
	my %opts = parse_opts('r', \@args, $usage);
	die $usage unless @args >= ($opts{r} ? 1 : 2);
	my $blocked_query = shift @args;
	if ($opts{r}) {
		# Unblock mode: clear blocked_by for matching tasks
		my @tasks = load_tasks();
		my @blocked_tasks = match_tasks($blocked_query, @tasks);
		return print "No tasks matching '$blocked_query'\n" unless @blocked_tasks;
		my %unblock_ids = map { $_->{id} => 1 } @blocked_tasks;
		my $n = 0;
		for my $t (@tasks) {
			next unless $unblock_ids{$t->{id}};
			$t->{blocked_by} = '';
			$n++;
		}
		save_tasks(@tasks);
		printf "Unblocked %d task(s)\n", $n;
		return;
	}
	my $blocking_query = join(' ', @args);
	die $usage unless $blocking_query;
	my @tasks	 = load_tasks();
	my @blocked_tasks = match_tasks($blocked_query, @tasks);
	return print "No tasks matching '$blocked_query'\n" unless @blocked_tasks;
	my @blocking_tasks = match_tasks($blocking_query, @tasks);
	return print "No tasks matching '$blocking_query'\n" unless @blocking_tasks;
	my %blocking_ids = map { $_->{id} => 1 } @blocking_tasks;
	my $n = 0;
	for my $t (@tasks) {
		next unless grep { ($_->{id} // 0) == ($t->{id} // 0) } @blocked_tasks;
		my @new_blocking_ids = grep { $_ != ($t->{id} // 0) } sort keys %blocking_ids;
		$t->{blocked_by} = join(' ', @new_blocking_ids);
		$n++;
	}
	save_tasks(@tasks);
	printf "Blocked %d task(s) by %d task(s)\n", $n, scalar keys %blocking_ids;
}

sub get_list_tasks {
	my @args = @_;
	my %opts = parse_opts_raw('acwRbBp:t:T:P:A:F:', \@args);
	my ($opt_a, $opt_c, $opt_w, $opt_R, $opt_b, $opt_B) = @opts{qw(a c w R b B)};
	my ($opt_A, $opt_F) = (defined $opts{A} ? $opts{A}[-1] : undef, defined $opts{F} ? $opts{F}[-1] : undef);
	my @filter_tags		= @{$opts{t} // []};
	my @filter_projects = @{$opts{p} // []};
	my @omit_tags		= @{$opts{T} // []};
	my @omit_projects	= @{$opts{P} // []};
	my $query = join(' ', @args);
	my @tasks = load_tasks();
	my %by_id = map { $_->{id} => $_ } @tasks;
	my @show;
	if ($opt_c) {
		@show = grep { ($_->{status} // '') eq 'done' } @tasks;
	} elsif ($opt_w) {
		@show = grep { ($_->{status} // '') eq 'waiting' } @tasks;
	} elsif ($opt_a) {
		@show = @tasks;
	} else {
		@show = grep { ($_->{status} // '') ne 'done' } @tasks;
	}
	if (defined $opt_A || defined $opt_F) {
		my $today = strftime('%Y-%m-%d', localtime);
		my $upper;
		my $lower;
		if (defined $opt_A) {
			if ($opt_A =~ /^\d+$/) {
				# -A 1 means today (0 days ahead), -A 2 includes tomorrow, etc.
				my $days_ahead = $opt_A > 0 ? $opt_A - 1 : 0;
				$upper = strftime('%Y-%m-%d', localtime(time + ($days_ahead * 86400)));
			} else {
				$upper = parse_timespec($opt_A) || $today;
			}
		}
		if (defined $opt_F) {
			if ($opt_F =~ /^\d+$/) {
				$lower = strftime('%Y-%m-%d', localtime(time - ($opt_F * 86400)));
			} else {
				$lower = parse_timespec($opt_F) || $today;
			}
		}
		if (defined $opt_A && defined $opt_F) {
			# cumulative window from -F date to -A date
		} elsif (defined $opt_A) {
			# No lower bound — include overdue/previously scheduled tasks
		} else {
			# with only -F, use a single-day window at the -F date
			$upper = $lower;
		}
		($lower, $upper) = ($upper, $lower) if defined($lower) && defined($upper) && $lower gt $upper;
		my $_date_from_str = sub {
			my ($date_str, $end_of_day) = @_;
			my ($y, $m, $d) = split /-/, $date_str;
			return $end_of_day
				? mktime(59, 59, 23, $d, $m - 1, $y - 1900)
				: mktime(0,  0,  0,  $d, $m - 1, $y - 1900);
		};
		@show = grep {
			my $sched = $_->{scheduled} // '';
			my $due   = $_->{due}       // '';
			my $date_match =
				($sched =~ /^\d{4}/ && (!defined $lower || $sched ge $lower) && $sched le $upper) ||
				($due   =~ /^\d{4}/ && (!defined $lower || $due   ge $lower) && $due   le $upper);
			my $cron_match = 0;
			unless ($date_match) {
				my $upper_epoch = $_date_from_str->($upper, 1);
				my $from_epoch  = defined $lower
					? $_date_from_str->($lower, 0) - 1
					: $_date_from_str->($today, 0) - 1;
				for my $expr (grep { is_cron_expr($_) } ($sched, $due)) {
					my $next = next_cron_occurrence($expr, $from_epoch);
					if (defined $next && $next <= $upper_epoch) {
						$cron_match = 1;
						last;
					}
				}
			}
			$date_match || $cron_match;
		} @show;
	}
	# -R: omit repeating tasks (cron expression in scheduled or due)
	@show = grep { !is_cron_expr($_->{scheduled}) && !is_cron_expr($_->{due}) } @show if $opt_R;
	# -b: show only blocked tasks; -B: omit blocked tasks
	my $_is_blocked = sub {
		my @ids = grep { /\S/ } split(/\s+/, $_[0]{blocked_by} // '');
		@ids && grep { !$by_id{$_} || ($by_id{$_}{status} // '') ne 'done' } @ids;
	};
	@show = grep { $_is_blocked->($_) } @show if $opt_b;
	@show = grep { !$_is_blocked->($_) } @show if $opt_B;
	# -t <tag> filters (AND): all specified tags must be present
	for my $tag (@filter_tags) {
		my $tl = lc $tag;
		@show = grep {
			my %task_tags = map { lc($_) => 1 } split(/\s+/, $_->{tags} // '');
			exists $task_tags{$tl}
		} @show;
	}
	# -T <tag> filters: omit tasks that have the tag
	for my $tag (@omit_tags) {
		my $tl = lc $tag;
		@show = grep {
			my %task_tags = map { lc($_) => 1 } split(/\s+/, $_->{tags} // '');
			!exists $task_tags{$tl}
		} @show;
	}
	# -p <project> filters (OR): task must belong to one of the specified projects
	if (@filter_projects) {
		my %proj_set = map { lc($_) => 1 } @filter_projects;
		@show = grep { $proj_set{lc($_->{project} // '')} } @show;
	}
	# -P <project> filters: omit tasks from these projects
	if (@omit_projects) {
		my %omit_set = map { lc($_) => 1 } @omit_projects;
		@show = grep { !$omit_set{lc($_->{project} // '')} } @show;
	}
	# Text query searches title and description only
	if ($query) {
		if ($query =~ /^\d+$/) {
			@show = grep { ($_->{id} // 0) == $query } @show;
		} else {
			my $lq = lc $query;
			@show = grep {
				index(lc($_->{title}	   // ''), $lq) >= 0 ||
				index(lc($_->{description} // ''), $lq) >= 0
			} @show;
		}
	}
	return sort_tasks(@show);
}

sub cmd_list {
	my $usage = 'Usage: list [-p <project>]... [-t <tag>]... [-T <tag>]... [-P <project>]... [-A <timespec>] [-F <timespec>] [-a|-c|-w] [-R] [-b|-B] [-v] <query>';
	my @args = @_;
	my %opts = parse_opts('acwRvbBp:t:T:P:A:F:', \@args, $usage);
	my @list_args;
	push @list_args, '-a' if $opts{a};
	push @list_args, '-c' if $opts{c};
	push @list_args, '-w' if $opts{w};
	push @list_args, '-R' if $opts{R};
	push @list_args, '-b' if $opts{b};
	push @list_args, '-B' if $opts{B};
	push @list_args, map { ('-p', $_) } @{$opts{p} // []};
	push @list_args, map { ('-t', $_) } @{$opts{t} // []};
	push @list_args, map { ('-T', $_) } @{$opts{T} // []};
	push @list_args, map { ('-P', $_) } @{$opts{P} // []};
	push @list_args, map { ('-A', $_) } @{$opts{A} // []};
	push @list_args, map { ('-F', $_) } @{$opts{F} // []};
	push @list_args, @args;
	my @tasks = get_list_tasks(@list_args);
	if ($opts{v}) {
		my $cols = 80;
		eval { ($cols) = GetTerminalSize() };
		my @all_tasks = load_tasks();
		my %by_id = map { $_->{id} => $_ } @all_tasks;
		# Build map from task id to list of its subtasks (tasks blocked by it)
		my %subtasks;
		for my $t (@all_tasks) {
			for my $pid (grep { /\S/ } split(/\s+/, $t->{blocked_by} // '')) {
				push @{$subtasks{$pid}}, $t;
			}
		}
		my ($title_w, $hdr, $row_fmt) = table_layout($cols);
		print $hdr, "\n";
		print "\x{2500}" x $cols, "\n";
		for my $t (@tasks) {
			my $desc_star = $t->{description} ? '*' : ' ';
			my $urgent = is_urgent($t);
			print BOLD if $urgent;
			printf $row_fmt,
				$t->{id} // '',
				substr(display_status($t, \%by_id), 0, $W_STATUS),
				substr($t->{project} // '', 0, $W_PROJECT),
				$title_w, substr($t->{title} // '', 0, $title_w),
				fmt_date($t->{scheduled}),
				fmt_date($t->{due}),
				substr(fmt_priority($t->{priority}), 0, $W_PRI),
				substr($t->{tags} // '', 0, $W_TAGS),
				$desc_star;
			print RESET if $urgent;
			for my $st (@{$subtasks{$t->{id} // 0} // []}) {
				printf "    %-4s %s\n", $st->{id} // '', $st->{title} // '';
			}
			if ($t->{description}) {
				printf "    %s\n", $_ for split(/\n/, $t->{description});
			}
		}
	} else {
		print_table(@tasks);
	}
}

sub cmd_kill {
	my $usage = 'Usage: kill [-p <project>]... [-t <tag>]... [-T <tag>]... [-P <project>]... [-A <timespec>] [-F <timespec>] [-a|-c|-w] [-R] [-b|-B] <query>';
	my @args = @_;
	parse_opts('acwRbBp:t:T:P:A:F:', \@args, $usage);
	my $query = join(' ', @args);
	die $usage unless $query;
	my @tasks	= load_tasks();
	my @removed = get_list_tasks(@_);
	return print "No matching tasks\n" unless @removed;
	my %rm = map { $_->{id} => 1 } @removed;
	save_tasks(grep { !$rm{$_->{id}} } @tasks);
	printf "Deleted %d task(s)\n", scalar @removed;
}

sub cmd_complete {
	my $usage = 'Usage: complete [-p <project>]... [-t <tag>]... [-T <tag>]... [-P <project>]... [-A <timespec>] [-F <timespec>] [-a|-r|-w] [-R] [-b|-B] <query>';
	my @args = @_;
	my %opts = parse_opts('arwRbBp:t:T:P:A:F:', \@args, $usage);
	my $query = join(' ', @args);
	die $usage unless $query;
	my $undo = $opts{r};
	my $new_status = $undo ? 'todo' : $opts{w} ? 'waiting' : 'done';
	my @tasks = load_tasks();
	my @list_args;
	push @list_args, '-a' if $opts{a};
	push @list_args, '-c' if $undo;
	push @list_args, '-R' if $opts{R};
	push @list_args, '-b' if $opts{b};
	push @list_args, '-B' if $opts{B};
	push @list_args, map { ('-p', $_) } @{$opts{p} // []};
	push @list_args, map { ('-t', $_) } @{$opts{t} // []};
	push @list_args, map { ('-T', $_) } @{$opts{T} // []};
	push @list_args, map { ('-P', $_) } @{$opts{P} // []};
	push @list_args, map { ('-A', $_) } @{$opts{A} // []};
	push @list_args, map { ('-F', $_) } @{$opts{F} // []};
	push @list_args, @args;
	my @candidate_tasks = get_list_tasks(@list_args);
	my %candidate = map { $_->{id} => 1 } @candidate_tasks;
	my $n = 0;
	for my $t (@tasks) {
		next unless $candidate{$t->{id}};
		$t->{status} = $new_status;
		$n++;
	}
	save_tasks(@tasks);
	printf "Marked %d task(s) as %s\n", $n, $new_status;
}

sub cmd_waiting {
	# alias for `modify -w <query>`
	my $usage = 'Usage: waiting <query>';
	die $usage unless @_ && join(' ', @_);
	cmd_modify('-w', @_);
}

sub cmd_edit {
	my $usage = 'Usage: edit <query>';
	my $query = join(' ', @_);
	die $usage unless $query;
	my @tasks = load_tasks();
	my $n = 0;
	for my $t (@tasks) {
		next unless match_tasks($query, $t);
		edit_task_yaml($t);
		$n++;
	}
	save_tasks(@tasks) if $n;
	printf "Edited %d task(s)\n", $n;
}

sub cmd_modify {
	my $usage		= 'Usage: modify [-d <timespec>] [-s <timespec>] [-p <project>] [-t <tag>]... [-T <tag>]... [-S] [-D] [-P] [-0|-1|-2|-3] [-w] <query>';
	my @args		= @_;

	# Extract numeric priority flags (-0, -1, -2, -3) before parse_opts
	my $set_priority = undef;
	my @filtered_args;
	for my $arg (@args) {
		if    ($arg eq '-0') { $set_priority = '';  }
		elsif ($arg eq '-1') { $set_priority = 1;   }
		elsif ($arg eq '-2') { $set_priority = 2;   }
		elsif ($arg eq '-3') { $set_priority = 3;   }
		else                 { push @filtered_args, $arg; }
	}
	@args = @filtered_args;

	my %opts		= parse_opts('d:s:t:T:p:wSDP', \@args, $usage);
	my @new_tags	= @{$opts{t} // []};
	my @remove_tags = @{$opts{T} // []};
	my $project		= $opts{p} ? $opts{p}[-1] : undef;
	my $due			= defined $opts{d} ? parse_timespec($opts{d}[-1]) : undef;
	my $sched		= defined $opts{s} ? parse_timespec($opts{s}[-1]) : undef;
	my $set_waiting	= $opts{w} ? 1 : 0;
	my $clear_sched	= $opts{S} ? 1 : 0;
	my $clear_due	= $opts{D} ? 1 : 0;
	my $clear_proj	= $opts{P} ? 1 : 0;
	die $usage unless @new_tags || @remove_tags || $project || $due || $sched || $set_waiting
		|| defined $set_priority || $clear_sched || $clear_due || $clear_proj;
	my $query = join(' ', @args);
	my @tasks = load_tasks();
	my $n = 0;
	for my $t (@tasks) {
		next unless match_tasks($query, $t);
		$t->{due}		= ''     if $clear_due;
		$t->{scheduled}	= ''     if $clear_sched;
		$t->{project}	= ''     if $clear_proj;
		$t->{due}		= $due   if defined $due;
		$t->{scheduled}	= $sched if defined $sched;
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
		$t->{project}  = $project      if defined $project;
		$t->{priority} = $set_priority if defined $set_priority;
		$t->{status}   = 'waiting'     if $set_waiting;
		$n++;
	}
	save_tasks(@tasks);
	printf "Modified %d task(s)\n", $n;
}

sub cmd_tag {
	my $usage = 'Usage: tag <tag> <query>';
	die $usage unless @_ >= 2;
	my ($tag, @rest) = @_;
	my $query = join(' ', @rest);
	die $usage unless $tag && $query;
	cmd_modify('-t', $tag, $query);
}

sub cmd_flush {
	my $usage = 'Usage: flush [-p <project>]... [-t <tag>]... [-T <tag>]... [-P <project>]... [-A <timespec>] [-F <timespec>] [-a|-c|-w] [-R] [-b|-B] <query>';
	my @args = @_;
	parse_opts('acwRbBp:t:T:P:A:F:', \@args, $usage);
	my $query = join(' ', @args);
	die $usage unless $query;
	my @tasks = load_tasks();
	my @selected = get_list_tasks(@_);
	my %rm = map { $_->{id} => 1 } grep { ($_->{status} // '') eq 'done' } @selected;
	my @kept = grep { !$rm{$_->{id}} } @tasks;
	my $removed = scalar keys %rm;
	my $id = 1;
	for my $t (@kept) {
		$t->{id} = $id++;
	}
	save_tasks(@kept);
	printf "Flushed %d done task(s)\n", $removed;
}

# ============================================================
# COMMAND DISPATCH
# ============================================================

our %CMD = (
	add			=> \&cmd_add,
	schedule	=> \&cmd_schedule,
	due			=> \&cmd_due,
	block		=> \&cmd_block,
	tag			=> \&cmd_tag,		# 'Usage: tag <tag> <query>'; alias for `modify -t <tag> <query>`
	list		=> \&cmd_list,
	ls			=> \&cmd_list,		# alias — excluded from prefix matching
	kill		=> \&cmd_kill,
	complete	=> \&cmd_complete,
	waiting		=> \&cmd_waiting,
	edit		=> \&cmd_edit,
	modify		=> \&cmd_modify,
	flush		=> \&cmd_flush,		# 'Usage: flush [-p <project>]... [-t <tag>]... [-T <tag>]... [-P <project>]... [-A <timespec>] [-F <timespec>] [-a|-c|-w] [-R] [-b|-B] <query>'; delete matching done tasks and renumber remaining tasks from 1
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
