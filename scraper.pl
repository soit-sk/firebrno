#!/usr/bin/env perl
# Copyright 2014 Michal Špaček <tupinek@gmail.com>

# Pragmas.
use strict;
use warnings;

# Modules.
use Database::DumpTruck;
use Encode qw(decode_utf8 encode_utf8);
use English;
use HTML::TreeBuilder;
use LWP::UserAgent;
use POSIX qw(strftime);
use URI;
use URI::QueryParam;
use Time::Local;

# Don't buffer.
$OUTPUT_AUTOFLUSH = 1;

# Mode (0 - Process all items, 1 - After one in database skip others).
my $MODE = 0;

# First page.
my $PAGE = 1;

# Page timeout.
my $TIMEOUT = 1;

# Decoding og months.
my $DATE_WORD_HR = {
	decode_utf8('leden') => 1,
	decode_utf8('únor') => 2,
	decode_utf8('březen') => 3,
	decode_utf8('duben') => 4,
	decode_utf8('květen') => 5,
	decode_utf8('červen') => 6,
	decode_utf8('červenec') => 7,
	decode_utf8('srpen') => 8,
	decode_utf8('září') => 9,
	decode_utf8('říjen') => 10,
	decode_utf8('listopad') => 11,
	decode_utf8('prosinec') => 12,
};

# District ids.
my $DISTRICT_IDS_HR = {
	3701 => decode_utf8('Blansko'),
	3702 => decode_utf8('Brno-město'),
	3703 => decode_utf8('Brno-venkov'),
	3704 => decode_utf8('Břeclav'),
	3706 => decode_utf8('Hodonín'),
	3712 => decode_utf8('Vyškov'),
	3713 => decode_utf8('Znojmo'),
};

# URI of service.
my $base_uri = URI->new("http://www.firebrno.cz/modules/incidents/index.php?page=$PAGE");

# Open a database handle.
my $dt = Database::DumpTruck->new({
	'dbname' => 'data.sqlite',
	'table' => 'data',
});

# Create a user agent object.
my $ua = LWP::UserAgent->new(
	'agent' => 'Mozilla/5.0',
);

# Get items.
my $page_uri = $base_uri;
while ($page_uri) {
	$page_uri = process_page($page_uri);
	sleep $TIMEOUT;
}

# Get database date from web datetime.
sub get_db_datetime {
	my $date_web = shift;
	my ($date, $time_web) = split m/,/ms, $date_web;
	my ($year, $mon, $day);
	if ($date =~ m/^\s*(\d+)\s*\.\s*(\w+)\s*(\d+)\s*$/ms) {
		$day = $1;
		$mon = $DATE_WORD_HR->{lc($2)};
		$year = $3;
	}
	remove_trailing(\$time_web);
	my ($hour, $min) = split m/:/ms, $time_web;
	my $time = timelocal(0, $min, $hour, $day, $mon - 1, $year - 1900);
	return strftime('%Y-%m-%d %H:%M', localtime($time));
}

# Get root of HTML::TreeBuilder object.
sub get_root {
	my $uri = shift;
	my $get = $ua->get($uri->as_string);
	my $data;
	if ($get->is_success) {
		$data = $get->content;
	} else {
		die "Cannot GET '".$uri->as_string." page.";
	}
	my $tree = HTML::TreeBuilder->new;
	$tree->parse(decode_utf8($data));
	return $tree->elementify;
}

# Process page.
sub process_page {
	my $uri = shift;
	print 'Page: '.$uri->as_string."\n";
	my $root = get_root($uri);
	my @items = $root->find_by_attribute('class', 'inc-item');
	foreach my $item (@items) {
		my ($date_div, $type_div) = $item->find_by_attribute('class', 'inc-info')
			->content_list;
		my $datetime = get_db_datetime($date_div->as_text);
		remove_trailing(\$datetime);
		my $type = $type_div->as_text;
		remove_trailing(\$type);
		my $link = URI->new($base_uri->scheme.'://'.$base_uri->host.
			'/modules/incidents/'.
			$item->find_by_attribute('class', 'inc-detail-link')
			->find_by_tag_name('a')->attr('href'));
		my $id = $link->query_param('filter[id]');
		my $district = $DISTRICT_IDS_HR->{$link->query_param('district_id')};
		my $details = $item->find_by_attribute('class', 'inc-content')->as_text;
		remove_trailing(\$details);
		my $summary = $item->find_by_tag_name('h3')->as_text;
		remove_trailing(\$summary);

		# Save.
		my $ret_ar = eval {
			$dt->execute('SELECT COUNT(*) FROM data WHERE ID = ?',
				$id);
		};
		if ($EVAL_ERROR || ! @{$ret_ar} || ! exists $ret_ar->[0]->{'count(*)'}
			|| ! defined $ret_ar->[0]->{'count(*)'}
			|| $ret_ar->[0]->{'count(*)'} == 0) {

			print "ID: $id - ".encode_utf8($summary)."\n";
			$dt->insert({
				'Summary' => $summary,
				'Details' => $details,
				'ID' => $id,
				'District' => $district,
				'Link' => $link->as_string,
				'Datetime' => $datetime,
				'Type' => $type,
			});
			# TODO Move to begin with create_table().
			$dt->create_index(['ID'], 'data', 1, 1);
		} else {
			if ($MODE == 1) {
				return;
			}
		}
	}
	return next_link($uri, $root);
}

# Get next link.
sub next_link {
	my ($uri, $root) = @_;
	my @pag_a = $root->find_by_attribute('class', 'paginator')
		->find_by_tag_name('a');
	my $next_uri;
	foreach my $pag_a (@pag_a) {
		if ($pag_a->as_text eq decode_utf8('›')) {
			$next_uri = URI->new($uri->scheme.'://'.$uri->host.
				$pag_a->attr('href'));
		}
	}
	return $next_uri;
}

# Removing trailing whitespace.
sub remove_trailing {
	my $string_sr = shift;
	${$string_sr} =~ s/^\s*//ms;
	${$string_sr} =~ s/\s*$//ms;
	return;
}
