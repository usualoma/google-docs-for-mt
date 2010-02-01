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

package GoogleDocs::Util;

use strict;
use warnings;

use LWP::UserAgent;
use HTTP::Request::Common qw(GET POST PUT DELETE);
use Net::Google::AuthSub;
use Encode;

use GoogleDocs::SAX;

our $base_url    = 'http://docs.google.com/feeds/default/private/full';
our $folders_url = 'http://docs.google.com/feeds/default/private/full/-/folder';
our $up_url      = 'http://docs.google.com/feeds/default/private/full/folder%3A%s/contents';
our $update_url  = 'http://docs.google.com/feeds/default/media/%2$s%3A%3$s';
our $delete_url  = 'http://docs.google.com/feeds/default/private/full/%s?delete=true';

our $search_url  = 'http://docs.google.com/feeds/default/private/full/folder%3A%s/contents';
#our $search_url  = 'http://docs.google.com/feeds/default/private/full';

sub _user_agent {
	use LWP::UserAgent;

	my $ua = LWP::UserAgent->new;
	$ua->timeout(10);
	if (my $proxy = MT->config('HTTPProxy')) {
		$ua->proxy('http', $proxy);
	}
	$ua->timeout(30);

	$ua;
}

sub _auth_sub {
	my ($cb, $user, $pass) = @_;
	my $app = MT->instance;
	my $blog = $app->blog;
	my $blog_id = $blog->id if $blog;
	my $scope = $blog_id ? ('blog:' . $blog_id) : 'system';
	my $plugin = $app->component('GoogleDocs');

	$user ||= $plugin->get_config_value('email', $scope);
	$pass ||= $plugin->get_config_value('password', $scope);

	if (! $user || ! $pass) {
		return $cb->error($plugin->translate("Email and Password is required"));
	}

	my $rec_key = 'googledocs_auth_sub:' . $user . $pass;
	my $rec = $app->request($rec_key);
	return $rec if $rec;

	my $auth = Net::Google::AuthSub->new(
		service => 'writely',
	);
	my $response = $auth->login($user, $pass);

	if ($response->is_success) {
		my %params = $auth->auth_params;
		$app->request($rec_key, \%params);
		\%params;
	} else {
		return $cb->error($plugin->translate(
			"Login failed: [_1]", $response->error
		));
	}
}

sub base_folder {
	my $app = MT->instance;
	my $blog = $app->blog;
	my $blog_id = $blog->id if $blog;
	my $scope = $blog_id ? ('blog:' . $blog_id) : 'system';
	my $plugin = $app->component('GoogleDocs');

	$plugin->get_config_value('base_folder', $scope) || '';
}

sub base_folder_id {
	my $app = MT->instance;
	my $blog = $app->blog;
	my $blog_id = $blog->id if $blog;
	my $scope = $blog_id ? ('blog:' . $blog_id) : 'system';
	my $plugin = $app->component('GoogleDocs');

	$plugin->get_config_value('base_folder_id', $scope) || '';
}

sub create_folder {
	my ($cb, $folder, $user, $pass) = @_;
	my $ua = &_user_agent();
	my $params = &_auth_sub($cb, $user, $pass)
		or return undef;
	my $app = MT->instance;
	my $plugin = $app->component('GoogleDocs');

	$params->{GData_Version} = '3.0';

	require XML::SAX;
	require MT::Util;

	my $parse = sub {
		my ($r) = @_;

		my $handler = GoogleDocs::GData::Handler->new(folder_title => $folder);
		my $parser = MT::Util::sax_parser();
		$parser->{Handler} = $handler;
		eval { $parser->parse_string($r->decoded_content); };

		if ($@) {
			my $error = $@;
			(1, $cb->error($plugin->translate("Error: [_1]", $error)));
		}
		elsif (
			$handler->{'detected_folder'}
			&& $handler->{'detected_folder'}{'id'} =~ m{/folder%3A(.*)}
		) {
			(1, $1);
		}
		else {
			(0, undef);
		}
	};

	my $request = GET($folders_url, %$params);
	my $r = $ua->request($request);
	if ($r->is_success) {
		my ($has_result, $id) = $parse->($r);
		return $id if $has_result;
	}
	else {
		return $cb->error($plugin->translate("Error: [_1]", $r->status_line));
	}

	$params->{Content_Type} = 'application/atom+xml';
	$params->{Content} = <<__EOC__;
<?xml version='1.0' encoding='UTF-8'?>
<entry xmlns="http://www.w3.org/2005/Atom">
	<category scheme="http://schemas.google.com/g/2005#kind"
		term="http://schemas.google.com/docs/2007#folder"/>
	<title>$folder</title>
</entry>
__EOC__

	$params->{Content_Length} = length($params->{Content});

	$request = POST($base_url, %$params);
	$r = $ua->request($request);

	if ($r->is_success) {
		my ($has_result, $id) = $parse->($r);
		if ($has_result) {
			return $id
		}
		else {
			return $cb->error($plugin->translate('Unkown error'));
		}
	}
	else {
		return $cb->error($plugin->translate("Error: [_1]", $r->status_line));
	}
}

sub upload {
	my ($cb, $opts) = @_;
	$opts ||= {};
	my $ua = &_user_agent();
	my $params = &_auth_sub($cb)
		or return undef;

	my $app = MT->instance;
	my $plugin = $app->component('GoogleDocs');

	my $id = $opts->{'id'} || '';
	my $title = $opts->{'title'} || $opts->{'file'};
	my $ext = $opts->{'ext'} || '';
	if (! $ext) {
		if (my $file = $opts->{'file'}) {
			($ext) = ($file =~ m/\.(.*)$/);
		}
	}

	$opts->{'type'} ||= {
		'doc' => 'application/msword',
		'pdf' => 'application/pdf',
		'xls' => 'application/vnd.ms-excel',
		'txt' => 'text/plain',
		'html' => 'text/plain',
		'xml' => 'text/plain',
	}->{$ext} || 'text/plain';

	$opts->{'kind'} ||= {
		'doc' => 'document',
		'pdf' => 'pdf',
		'xls' => 'spreadsheet',
		'txt' => 'document',
		'html' => 'document',
		'xml' => 'document',
	}->{$ext} || 'document';

	$params->{GData_Version} = '3.0';

	my $content = $opts->{'content'}
		? ${ $opts->{'content'} }
		: do { open(my $fh, '<', $opts->{'file'}); local $/; <$fh>; };
	if (Encode::is_utf8($content)) {
		$content = Encode::encode('utf-8', $content);
	}
	if (Encode::is_utf8($title)) {
		$title = Encode::encode('utf-8', $title);
	}

	my $entry_open_tag;
	if ($opts->{'etag'}) {
		# FIXME
		$opts->{'etag'} = '*';

		$entry_open_tag = qq#<entry xmlns="http://www.w3.org/2005/Atom" xmlns:docs="http://schemas.google.com/docs/2007" xmlns:gd="http://schemas.google.com/g/2005" gd:etag="$opts->{'etag'}">#;
	}
	else {
		$entry_open_tag = qq#<entry xmlns="http://www.w3.org/2005/Atom" xmlns:docs="http://schemas.google.com/docs/2007">#;
	}

	my $boundary = 'END_OF_PART';
	while ($content =~ m/$boundary/) {
		$boundary .= 'T';
	}

	$params->{Content_Type} = "multipart/related; boundary=$boundary";
	$params->{Content} = <<__EOC__;
--$boundary
Content-Type: application/atom+xml

<?xml version='1.0' encoding='UTF-8'?>
$entry_open_tag
<category scheme="http://schemas.google.com/g/2005#kind"
	term="http://schemas.google.com/docs/2007#$opts->{'kind'}"/>
  <title>$title</title>
  <docs:writersCanInvite value="false" />
</entry>

--$boundary
Content-Type: $opts->{'type'}

$content

--$boundary--
__EOC__
	$params->{Content_Length} = length($params->{Content});

	$params->{Slug} = $title;
	#$params->{'X-HTTP-Method-Override'} = 'DELETE';        

	#$params->{'If_Match'} = $opts->{'etag'}; #<ETag or * here>

	my $url = $id
		? sprintf($update_url, &base_folder_id, $opts->{'kind'}, $id)
		: sprintf($up_url, &base_folder_id);


	my $request = $id ? PUT($url, %$params) : POST($url, %$params);
	my $r = $ua->request($request);

	if ($r->is_success) {
		my $c = $r->decoded_content;
		if (! $id) {
			($id) = ($c =~ m{<id>.*?\%3A(.*?)</id>});
		}
		my ($etag) = ($c =~ m{gd:etag=['"]\&quot;(.*?)\&quot;});
		return ($id, $etag);
	}
	else {
		if ($r->code == 404) {
			# Try to upload
			delete($opts->{'id'});
			delete($opts->{'etag'});
			return &upload($cb, $opts);
		}
		else {
			return (
				$cb->error($plugin->translate("Error: [_1]", $r->status_line)),
				undef
			);
		}
	}
}

sub delete {
	my ($cb, $opts) = @_;
	$opts ||= {};
	my $ua = &_user_agent();
	my $params = &_auth_sub($cb)
		or return undef;

	my $id = $opts->{'id'}
		or return 1;

	my $app = MT->instance;
	my $plugin = $app->component('GoogleDocs');

	$params->{GData_Version} = '3.0';
	
	$params->{If_Match} = $opts->{'etag'};
	# FIXME
	$params->{If_Match} = '*';

	my $url = sprintf($delete_url, $id);

	my $request = DELETE($url, %$params);
	my $r = $ua->request($request);

	if ($r->is_success) {
		return $r->code;
	}
	else {
		if ($r->code == 404) {
			return $r->code;
		}
		else {
			return $cb->error($plugin->translate("Error: [_1]", $r->status_line));
		}
	}
}

sub search {
	my ($cb, $word, $limit, $start_index, $start_key) = @_;
	my $ua = &_user_agent();
	my $params = &_auth_sub($cb)
		or return undef;

	my $app = MT->instance;
	my $plugin = $app->component('GoogleDocs');

	$params->{GData_Version} = '3.0';

#	if (Encode::is_utf8($word)) {
#		$word = Encode::encode('utf-8', $word);
#	}

	my $url =
		sprintf($search_url, &base_folder_id)
		. "?q=$word&max-results=$limit"
		. ($start_key ? "&start-key=$start_key" : '')
		. ($start_index ? "&start-index=$start_index" : '');

	my $request = GET($url, %$params);
	my $r = $ua->request($request);

	if ($r->is_success) {
		my $handler = GoogleDocs::Search::GData::Handler->new();
		my $parser = MT::Util::sax_parser();
		$parser->{Handler} = $handler;
		eval { $parser->parse_string($r->decoded_content); };

		if ($@) {
			my $error = $@;
			return $cb->error($plugin->translate("Error: [_1]", $error));
		}
		else {
			$app->{'googledocs_next'} = $handler->{'next'};
			$app->{'googledocs_previous'} = $handler->{'previous'};

			my @ids = map($_->{'id'}, @{ $handler->{'entries'} });
			my @objs = (
				MT::Entry->load({
					googledocs_id => \@ids,
				}),
				MT::Asset->load({
					class => '*',
					googledocs_id => \@ids,
				}),
			);
			my @all = ();
			foreach my $id (@ids) {
				push(@all, grep($id eq $_->googledocs_id, @objs));
			}
			return (scalar(@all), @all);
		}
	}
	else {
		return (
			$cb->error($plugin->translate("Error: [_1]", $r->status_line)),
			undef
		);
	}
}

1;
