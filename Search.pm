package Craigslist::Search;

use strict;
use warnings;
use HTTP::Request;
use LWP::UserAgent;
use HTML::TreeBuilder::XPath;
use Scalar::Util "blessed";
use DBI;
use DateTime::Format::Strptime;
use POSIX qw(ceil);

our $VERSION = "0.001";

my $homedir = (getpwuid $>)[7];
my $dbfile = "$homedir/.craigslist-search.db";

my $optmap = {
	min => "minAsk",
	max => "maxAsk",
	query => "query",
	sort => "sort",
	s => "s",
	haspic => "hasPic"
};
my @valid_qs = qw(s min max query sort haspic);
my @valid_opts = qw(limit);

my $ua = LWP::UserAgent->new();
my $dbh = DBI->connect("dbi:SQLite:dbname=$dbfile","","");
my $year = (localtime(time))[5] + 1900;
my $parser = DateTime::Format::Strptime->new(pattern => "%Y-%b-%d %H:%M:%S");

sub new {
	my $class = shift;
	my $self = {};
	my $opts = {};
	my @qs;

	bless ($self, $class);
	$self->{_count} = 0;
	$self->setup;

	if (@_) {
		$self->{_opts} = shift;
		# City
		if ($self->{_opts}->{city}) {
			$self->_validate_city($self->{_opts}->{city});
			delete $self->{_opts}->{city};
		}

		# Category
		if ($self->{_opts}->{category}) {
			$self->_validate_category($self->{_opts}->{category});
			delete $self->{_opts}->{category};
		}

		# Other options
		$self->_validate_opts;
	}
	return $self;
}

sub city {
	my $self = shift;
	if (@_) {
		my $city = shift;
		$self->_validate_city($city);
		return $self;
	} else {
		return $self->{_city} || undef;
	}
}

sub category {
	my $self = shift;
	if (@_) {
		my $category = shift;
		$self->_validate_category($category);
		return $self;
	} else {
		return $self->{_category} || undef;
	}
}

sub query {
	my $self = shift;
	if (@_) {
		$self->{_qs}->{query} = shift;
		return $self;
	} else {
		return $self->{_qs}->{query} || undef;
	}
}

sub sort {
	my $self = shift;
	my @valid_sort = qw(date rel);
	if (@_) {
		my $sort = shift;
		if (grep(/^$sort$/, @valid_sort)) {
			$self->{_qs}->{sort} = $sort;
			return $self;
		} else {
			$self->_error_exit(sprintf("invalid sort option: \"%s\".", $sort));
		}
	} else {
		return $self->{_qs}->{sort} || undef;
	}
}

sub haspic {
	my $self = shift;
	my @valid_haspic = qw(yes no);
	if (@_) {
		my $haspic = shift;
		if (grep(/^$haspic$/, @valid_haspic)) {
			if ($haspic eq "yes") {
				$self->{_qs}->{haspic} = 1;
			}
		} else {
			$self->_warn_text(sprintf("invalid haspic option: \"%s\".", $haspic));
		}
	}
}

sub limit {
	my $self = shift;
	if (@_) {
		my $limit = shift;
		$self->_validate_limit($limit);
	} else {
		return $self->{_limit} || undef;
	}
}

sub count {
	my $self = shift;
	return $self->{_count} || undef;
}

sub ads {
	my $self = shift;
	return $self->{_ads} || undef;
}

sub search {
	my $self = shift;
	my @qs;
	$self->{_qs}->{s} = 0;
	my ($url, $content);

	if ($self->{_city} && $self->{_base} && $self->{_href} && $self->{_qs}->{query}) {
		# Parse the query string
		while (my ($key, $value) = each(%{$self->{_qs}})) {
			if (grep(/^$key$/, @valid_qs)) {
				push(@qs, sprintf("%s=%s", $optmap->{$key}, $value));
			}
		}

		# Construct the URL
		$url = sprintf(
			"%s/search/%s?%s",
			$self->{_base},
			$self->{_href},
			join("&", @qs)
		);
		push (@{$self->{_urls}}, $url);

		$content = $self->_fetch_url($url);
		if ($content) {
			my $tree= HTML::TreeBuilder::XPath->new();
			$tree->parse($content);
			$tree->eof;

			#$self->{_resultcount} = int($tree->findvalue('//div[@class="toc_legend"]/div/span[2]/span[3]/span'));
			$self->process_results($tree);

			# A ghetto way to process the rest of the results
			my $remaining;
			if ($self->{_limit}) {
				$remaining = ceil( $self->{_limit} / 100 ) - 1;
			} else {
				$remaining = ceil( $self->{_resultcount} / 100 ) - 1;
			}
			for (my $x = 1; $x <= $remaining; $x++) {
				@qs = ();
				$self->{_qs}->{s} = $x * 100;
				while (my ($key, $value) = each(%{$self->{_qs}})) {
					if (grep(/^$key$/, @valid_qs)) {
						push(@qs, sprintf("%s=%s", $key, $value));
					}
				}

				$url = sprintf(
					"%s/search/%s?%s",
					$self->{_base},
					$self->{_href},
					join("&", @qs)
				);
				push (@{$self->{_urls}}, $url);

				$content = $self->_fetch_url($url);
				if ($content) {
					my $tree= HTML::TreeBuilder::XPath->new();
					$tree->parse($content);
					$tree->eof;
					$self->process_results($tree);
				}
			}
		}
	} else {
		$self->_error_exit("missing city and/or query options. cannot continue.");
	}
}

sub process_results {
	my $self = shift;
	my $tree = shift;

	my @ads = $tree->look_down( _tag => "p", class => "row");
	foreach my $p (@ads) {
		my ($month, $day, $unix_date, $date, $title, $href, $location, $price, $has_pic);

		# Ad date
		$date = $p->findvalue('.//span[@class="date"]');
		($month, $day) = split(/\s+/, $date);
		$day = sprintf("%02d", $day);
		$unix_date = $parser->parse_datetime( sprintf("%s-%s-%s 00:00:00", $year, $month, $day) )->epoch;

		# Ad title and link
		my $a = $p->findnodes('.//span[@class="pl"]/a')->[0];
		$title = $a->as_text;
		$title = join " ", map {ucfirst} split /\s+/, lc($title);
		$href = $a->attr("href");
		$href = sprintf("%s%s", $self->{_base}, $href);

		# Ad price
		$price = $p->findvalue('.//span[@class="l2"]/span[@class="price"]');

		# Ad has a pic
		#$has_pic = $p->findvalue('.//span[@class="px"]/span[@class="p"]');
		$has_pic = $p->findvalue('.//span[@class="px"]/span[@class="p"]') =~ m/pic/ ? 1 : 0;

		# Ad location
		$location = $p->findvalue('.//span[@class="pnr"]/small');
		$location =~ s/^\s*\(\s*//; $location =~ s/\s*\)\s*$//;
		$location = join " ", map {ucfirst} split /\s+/, lc($location);

		push (@{$self->{_ads}->{$unix_date}},
			{
				date => $unix_date || "NO DATE",
				url => $href || undef,
				title => $title || undef,
				price => $price || undef,
				location => $location || undef,
				has_pic => $has_pic || 0
			}
		);
		$self->{_count}++;
	}
}

sub setup {
	my $self = shift;
	my ($select, $count, $updated);
	my $now = time;
	my $max_seconds = 86400 * 7;

	# Does the DB schema exist?
	$select = "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name IN ('cities','categories');";
	$count = $dbh->selectrow_array($select);
	if ($count != 2) {
		$self->_warn_text("the database is missing or corrupt - recreating.");
		$dbh->do("DROP TABLE IF EXISTS cities");
		$dbh->do("DROP TABLE IF EXISTS categories");
		$dbh->do("CREATE TABLE cities (country TEXT, city TEXT, subregions TEXT, url TEXT, updated INTEGER)");
		$dbh->do("CREATE TABLE categories (name TEXT, category TEXT, href TEXT, updated INTEGER)");
		$self->_info_text("done!");

		$self->load_data;
		return $self;
	}

	# Is the data stale?
	$select = "SELECT MIN(updated) FROM cities LIMIT 1";
	$updated = $dbh->selectrow_array($select);
	if ($updated) {
		if (($now - $updated) > $max_seconds) {
			$self->_info_text("data is stale. forcing a refresh.");
			$self->load_data;
			return $self;
		}
	} else {
		$self->load_data;
		return $self;
	}

}

sub load_data {
	my $self = shift;
	my ($tree, $url, $req, $res, $content, @links);
	my ($sth, $insert, $select, $row, $count, $updated);
	my $now = time;

	$self->_info_text("refreshing the database.");
	# Load countries
	my $countries = {
		"usa" => "us",
		"canada" => "ca",
		"china" => "cn"
	};

	foreach my $country (keys %$countries) {
		$url = sprintf("http://geo.craigslist.org/iso/%s", $countries->{$country});

		$req = HTTP::Request->new("GET", $url);
		$res = $ua->request($req);
		$content = $res->content;
		$tree = HTML::TreeBuilder->new();
		$tree->parse($content);
		$tree->eof;

		@links = $tree->look_down( _tag => "a");
		# clean up the foreach here
		foreach my $link (@links) {
			my ($city, $href);
			$href = $link->attr("href");
			$href =~ s/\/$//;
			next if $href =~ /www\.craigslist\.org/;
			if ($href =~ m/^http:\/\/([^\.]+)\.craigslist/) {
				$city = $1;
				$insert = sprintf(
					"INSERT OR REPLACE INTO cities (country, city, url, updated) VALUES ('%s', '%s', '%s', '%s')",
					$country, $city, $href, $now
				);
				$dbh->do($insert);
			}
		}
	}

	# Load categories
	my $categories = {
		sss => "forsale",
		bbb => "services",
		ccc => "community",
		hhh => "housing",
		jjj => "jobs",
		ggg => "gig"
	};

	$url = "http://sandiego.craigslist.org/";

	$req = HTTP::Request->new("GET", $url);
	$res = $ua->request($req);
	$content = $res->content;
	$tree = HTML::TreeBuilder->new();
	$tree->parse($content);
	$tree->eof;

	foreach my $key (keys %$categories) {
		my $div = $tree->look_down( _tag => "div", id => $key );
		@links = $div->look_down( _tag => "a" );
		foreach my $link (@links) {
			my ($name, $category, $href) = ($link->as_text, $categories->{$key}, $link->attr("href"));

			# two overrides - damn you, craigslist...
			$href = "mca" if $name eq "motorcycles";
			$href = "cta" if $name eq "cars+trucks";
			next if $name eq "[ part-time ]";

			$href =~ s/^\///; $href =~ s/\/$//;
			$insert = "INSERT OR REPLACE INTO categories (name, category, href, updated) VALUES (?, ?, ?, ?)";
			$sth = $dbh->prepare($insert);
			$sth->execute($name, $category, $href, $now);
		}
	}
	$self->_info_text("done!");
	return $self;
}

sub _fetch_url {
	my $self = shift;
	my $url = shift;
	my ($req, $res, $rc, $return);

	$req = HTTP::Request->new("GET", $url);
	$res = $ua->request($req);
	if ($res->is_success) {
		$rc = $res->code;
		if ($rc == 200) {
			$return = $res->content;
		}
	}
	return $return;
}

sub _validate_city {
	my $self = shift;
	my $opt_city = shift;
	my ($current_city, $current_url, $city, $url);

	if ($self->{_city} && $self->{_base}) {
		$current_city = $self->{_city};
		$current_url = $self->{_base};
	}

	my $select = sprintf(
		"SELECT city,url FROM cities WHERE city = '%s'",
		$opt_city
	);
	($city, $url) = $dbh->selectrow_array($select);

	if ($city && $url) {
		$self->{_city} = $city;
		$self->{_base} = $url;
		return $self;
	} else {
		if ($current_city) {
			$self->_warn_text(sprintf("invalid city: \"%s\". reverting to previously selected city.", $opt_city));
		} else {
			$self->_error_exit(sprintf("invalid city: \"%s\".", $opt_city));
		}
	}
}

sub _validate_category {
	my $self = shift;
	my $opt_name = shift;
	my ($current_category,$current_href, $category, $href);

	if ($self->{_category} && $self->{_href}) {
		$current_category = $self->{_category};
		$current_href = $self->{_href};
	}

	my $select = sprintf(
		"SELECT category,href FROM categories WHERE name ='%s'",
		$opt_name
	);
	($category, $href) = $dbh->selectrow_array($select);

	if ($category && $href) {
		$self->{_category} = $category;
		$self->{_href} = $href;
		return $self;
	} else {
		if ($current_category) {
			$self->_warn_text(sprintf("invalid category: \"%s\". reverting to previously selected category.", $opt_name));
		} else {
			$self->_error_exit(sprintf("invalid category: \"%s\".", $opt_name));
		}
	}
}

sub _validate_opts {
	my $self = shift;
	while (my ($key, $value) = each %{$self->{_opts}}) {
		if (grep(/^$key$/, @valid_qs)) {
			$self->{_qs}->{$key} = $value;

		} else {
			$self->_warn_text(sprintf("\%s\% is an invalid option - ignoring.", $key));
		}
	}
	delete $self->{_opts};
	return $self;
}

sub _validate_limit {
	my $self = shift;
	my $limit = shift;
	if ($limit =~ m/^[0-9]+$/) {
		if ($limit < 100) {
			$self->_warn_text("limit must be greater than 100. ignoring.");
		} else {
			$self->{_limit} = $limit;
		}
	} else {
		$self->_warn_text("limit must be an integer. ignoring.");
	}
}

sub _error_exit {
	my $self = shift;
	my $text = shift;
	print STDERR"[Error] $text\n";
	exit;
}

sub _warn_text {
	my $self = shift;
	my $text = shift;
	print STDOUT "[Warn] $text\n";
}

sub _info_text {
	my $self = shift;
	my $text = shift;
	print STDOUT "[Info] $text\n";
}
1;

=head1 NAME

 Craigslist::Search - Perl interface to Craigslist Search

=head1 SYNOPSIS

 use Craigslist::Search;
 $cl = Craigsist::Search->new({city => "sfbay", query => "Honda Accord", haspics => "yes"});
 $cl->search;

=head1 DESCRIPTION

 Craigslist::Search provides a simple interface to Craigslist. It allows you to specify city, category,
 min/max prices for "forsale" ads, etc.

=head1 CONSTRUCTOR

 $cl = Craigsist::Search->new();
    Creates a new Craigsist::Search instance. You can specify all of the options in the constructor or
    none at all. However, in order to search you must minimally supply a city name and a query.

=head1 METHODS

 $cl->city($city)
    This method sets the city name for the search. The city names should match the city names used
    by Craigslist. e.g. sfbay, sandiego.

 $cl->category($category)
    This method sets the Craigslist category for your search. These should also match the category names
    used by Craigslist. e.g. boats, furniture, internet engineers, etc. This module is not limited to
    for sale ads. The following category groups are supported: community, housing, for sale, services,
    jobs, and gigs.

 $cl->query($query)
    This method sets the name of the item you're search for. It can be anything you like.

 $cl->sort($sort)
    This method sets the sort order for the results by relevance (rel) or by date (date).

 $cl->limit($limit)
    This limit accept an integer over 100 and sets the limit for the number of results to return.
    This number is rounded up to the nearest 100.

 $cl->haspic(yes|no)
    This method, when set to yes, only fetches ads that have pictures attached.

 $cl->search
    This method executes the search based on the specified criteria. Results will be stored in the object.

 $cl->ads
    This method is a Perl Dumper representation of the output.

 $cl->count
    This method displays the number of ads returned in your search.
