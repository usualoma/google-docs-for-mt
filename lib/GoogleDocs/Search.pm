# Copyright (c) 2010 ToI-Planning, All rights reserved.
# 
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
# 
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
# 
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
# THE SOFTWARE.
#
# $Id$

package GoogleDocs::Search;

use strict;
use warnings;

use SearchEngine::Search;
use base qw/ SearchEngine::Search /;

use GoogleDocs::Util;

sub process { __PACKAGE__->SUPER::process(@_); }

sub context_script {
	my ($ctx, $args) = @_;

	require MT;
	my $app = MT->instance;

	my $cgipath = ($ctx->handler_for('CGIPath'))[0]->($ctx, $args);
	my $script = $ctx->{config}->SearchScript;

	my @ignores = (
		'startIndex', 'limit', 'offset', 'format', 'page',
		'start-index', 'start-key'
	);
	my $q = new CGI('');
	if ($app->isa('MT::App::Search')) {
		foreach my $p ($app->param) {
			if (! grep({ $_ eq $p } @ignores)) {
				$q->param($p, $app->param($p));
			}
		}
	}

	local $CGI::USE_PARAM_SEMICOLONS;
	$CGI::USE_PARAM_SEMICOLONS = 0;
	$cgipath . $script . '?' . $q->query_string;
}

sub prepare_context {
	my $app = shift;
	my $ctx = $app->SUPER::prepare_context(@_);

	my $pagerblock = $ctx->handler_for('pagerblock');
	$pagerblock->code(sub { ''; });

	my $ifpreviousresults = $ctx->handler_for('ifpreviousresults');
	$ifpreviousresults->code(sub { $app->{'googledocs_previous'} });

	my $ifmoreresults = $ctx->handler_for('ifmoreresults');
	$ifmoreresults->code(sub { $app->{'googledocs_next'} });

	my %param_map = qw(
		max-results limit
	);
	my $next_prev = sub {
		my ($type, $ctx, $args) = @_;

		my $next = $app->{'googledocs_' . $type}
			or return '';

		my $link = &context_script($ctx, $args);

		my $prefix;
		if ($link) {
			if (index($link, '?') > 0) {
				$prefix = '&';
			}
			else {
				$prefix = '?';
			}
		}

		while (my ($k, $v) = each(%$next)) {
			$k = $param_map{$k} if $param_map{$k};
			$link .= "$prefix$k=$v";
			$prefix = '&';
		}

		return $link;
	};

	my $nextlink = $ctx->handler_for('nextlink');
	$nextlink->code(sub {
		$next_prev->('next', @_);
	});

	my $previouslink = $ctx->handler_for('previouslink');
	$previouslink->code(sub {
		$next_prev->('previous', @_);
	});

	$ctx
}

sub _search {
    my $app = shift;
    my $q   = $app->param;

	my $site = $app->_site;

	my $limit = $app->param('limit') || 20;
	my $search = $app->{'search_string'};
	# file format
	my $format = $app->_format;

	my $cb = new MT::ErrorHandler;
	my ($total, @objs) = GoogleDocs::Util::search(
		$cb, $search, $limit,
		$app->param('start-index') || undef,
		$app->param('start-key') || undef,
	);
	die($cb->errstr) unless defined($total);

	my %res = ();
	$res{'total'} = $total;
	$res{'results'} = [ map({
		bless {
			(ref $_ eq 'MT::Entry' ? (entry => $_) : ()),
			(ref $_ eq 'MT::Asset' ? (asset => $_) : ()),
		}, 'SearchEngine::Result';
	} @objs) ];

	return \%res;
}

sub web {
    my $app = shift;
	$app->_search(@_);
}

sub images {
    my $app = shift;
	$app->_search(@_);
}

sub blog {
	my $app = shift;
	my ($blog_id) = $app->blog_ids;
	$app->model('blog')->load($blog_id);
}

1;
