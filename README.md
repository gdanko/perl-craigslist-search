# Craigslist::Search

Craigslist::Search provides an easy way to search Craigslist. While fully functional it is still a work in progress.

## Overview
Its features include:

 * SQLite DB for storying city/category data. Only refreshed when the module cannot find if it is considered "stale".
 * Ability to select city and category for a more granular search.
 * Sort by either relevance or date.
 * Select a limit for the number of results to return.
 * Only show results with photos.
 
The output format is an array of hashrefs containing search results.

## Examples
### Example script
```perl
#!/usr/bin/perl

use strict;
use warnings;
use lib "/home/gdanko/craigslist-search";
use Data::Dumper;
use Craigslist::Search;

my $cl = Craigslist::Search->new;
$cl->city("sandiego");
$cl->category("electronics");
$cl->query("iPhone");
$cl->haspic("yes");
$cl->limit("200");
$cl->search;
print Dumper(\$cl->{_ads});
```

### Sample output (results truncated)
```
[Warn] the database is missing or corrupt - recreating.
[Info] done!
[Info] refreshing the database.
[Info] done!
$VAR1 = \{
            '1402617600' => [
                              {
                                'has_pic' => 1,
                                'date' => 1402617600,
                                'location' => 'San Diego',
                                'price' => '$115',
                                'url' => 'http://sandiego.craigslist.org/csd/ele/4499774269.html',
                                'title' => 'Cisco 3g Microcell Tower--at&t'
                              },
                              {
                                'location' => 'Mira Mesa / Mission Valley',
                                'date' => 1402617600,
                                'has_pic' => 1,
                                'title' => 'Mobile Sound System For Ipad 1,2,3 Wireless Headphones Brand New',
                                'url' => 'http://sandiego.craigslist.org/csd/ele/4513047598.html',
                                'price' => '$25'
                              }
                            ]
          };
```
