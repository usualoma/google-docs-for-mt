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

package GoogleDocs;

use GoogleDocs::Util;

use strict;
use warnings;

sub enabled {
	my $blog_id = shift;
	if (! $blog_id) {
		my $blog = MT->instance->blog
			or return 0;
		$blog_id = $blog->id;
	}
	my $plugin = MT->component('GoogleDocs');
	$plugin->get_config_value('enabled', 'blog:' . $blog_id);
}

sub show_error {
	my ($msg) = @_;
	if (ref $msg) {
		$msg = $msg->errstr;
	}

	my $app = MT->instance;
	my $plugin = $app->component('GoogleDocs');

	$app->send_http_header;
	$app->print($app->show_error($plugin->translate($msg)));
	$app->{no_print_body} = 1;
	exit();
}

sub _hdlr_email {
	my ($ctx, $args) = @_;
	my $plugin = MT->component('GoogleDocs');
	my $blog = $ctx->stash('blog')
		or return '';

	$plugin->get_config_value('email', 'blog:' . $blog->id);
}

sub _hdlr_password {
	my ($ctx, $args) = @_;
	my $plugin = MT->component('GoogleDocs');
	my $blog = $ctx->stash('blog')
		or return '';

	$plugin->get_config_value('password', 'blog:' . $blog->id);
}

sub _hdlr_base_folder_id {
	my ($ctx, $args) = @_;
	my $plugin = MT->component('GoogleDocs');
	my $blog = $ctx->stash('blog')
		or return '';

	$plugin->get_config_value('base_folder_id', 'blog:' . $blog->id);
}

sub _hdlr_index {
	my ($ctx, $args, $cond) = @_;
	my $type = $args->{'object'} || 'entry';

	require MT::Util;
	my $t = {
		entry => {
			get_obj => sub {
				my ($ctx) = @_;
				$ctx->stash('entry');
			},
			get_title => sub {
				my ($obj) = @_;
				MT::Util::encode_xml($obj->title, 1);
			},
		},
	}->{$type};

	my $obj  = $t->{get_obj}($ctx);
	my $content = $ctx->slurp($args, $cond);
	if (Encode::is_utf8($content)) {
		$content = Encode::encode('utf-8', $content);
	}

	my $md5 = Digest::MD5::md5_hex($content);
	my $old_md5 = $obj->googledocs_md5;
	if (! defined($old_md5) || $old_md5 ne $md5) {
		my $cb = new MT::ErrorHandler;
		my ($id, $etag) = GoogleDocs::Util::upload($cb, {
			id      => $obj->googledocs_id,
			etag    => $obj->googledocs_etag,
			title   => $t->{get_title}($obj),
			content => \$content,
		});
		&show_error($cb) unless $id;

		$obj->googledocs_md5($md5);
		$obj->googledocs_id($id);
		$obj->googledocs_etag($etag);
		$obj->save;
	}

	($args->{display} && $args->{display} eq 'hidden') ? '' : $content;
}


sub _hdlr_id {
	my ($ctx, $args) = @_;
	my $type =
		$args->{'object'}
		|| ($ctx->stash('asset') ? 'asset' : 'entry');
	my $obj;

	if ($type eq 'entry') {
		$obj = $ctx->stash($type)
			or return $ctx->_no_entry_error();
	}
	elsif ($type eq 'asset') {
		$obj = $ctx->stash($type)
			or return $ctx->_no_asset_error();
	}
	else {
		return $ctx->_no_entry_error();
	}

	$obj->googledocs_id;
}

sub _hdlr_zend_framework_path {
	my ($ctx, $args) = @_;
	my $app = MT->instance;
	my $plugin = $app->component('GoogleDocs');
	require File::Spec;
	File::Spec->catfile($plugin->{full_path}, 'zend_framework');
}

sub entry_post_save {
	my ($cb, $obj, $original) = @_;

	return 1 unless &enabled($obj->blog_id);

	if ($obj->status != MT::Entry::RELEASE()) {
		my ($status) = GoogleDocs::Util::delete($cb, {
			id => $obj->googledocs_id,
		});
		&show_error($cb) unless $status;
	}

	1;
}

sub object_post_remove {
	my ($cb, $obj, $original) = @_;

	return 1 unless &enabled($obj->blog_id);

	my ($status) = GoogleDocs::Util::delete($cb, {
		id => $obj->googledocs_id,
	});
	&show_error($cb) unless $status;

	1;
}

sub entry_pre_save {
	my ($cb, $obj, $original) = @_;

	return 1 unless &enabled($obj->blog_id);
	return 1 if $obj->googledocs_md5;

	require Digest::MD5;
	$obj->googledocs_md5(Digest::MD5::md5_hex(
		Encode::encode('utf-8', $obj->title) || 'dummy'
	));

	my $title = MT::Util::encode_xml($obj->title, 1);
	my ($id, $etag) = GoogleDocs::Util::upload($cb, {
		title => $title,
		content  => \$title,
	});
	&show_error($cb) unless $id;

	$obj->googledocs_id($id);
	$obj->googledocs_etag($etag);
	$original->googledocs_id($id);
	$original->googledocs_etag($etag);

	return 1;
}

sub asset_pre_save {
	my ($cb, $obj, $original) = @_;

	return 1 unless &enabled($obj->blog_id);

	require Digest::MD5;
	my $md5 = Digest::MD5::md5_hex(
		do{ open(my $fh, '<', $obj->file_path); local $/; <$fh> }
	);
	my $old_md5 = $obj->googledocs_md5;

	if (! defined($old_md5) || $old_md5 ne $md5) {
		my $title = $obj->label;
		if (! $title) {
			$title = $obj->file_path;
			if (my $blog = $obj->blog) {
				$title =~ s/^$blog->site_path//;
			}
		}

		my ($id, $etag) = GoogleDocs::Util::upload($cb, {
			id    => $obj->googledocs_id,
			etag    => $obj->googledocs_etag,
			title => $title,
			file  => $obj->file_path,
		});
		&show_error($cb) unless $id;

		$obj->googledocs_md5($md5);
		$obj->googledocs_id($id);
		$obj->googledocs_etag($etag);
	}

	return 1;
}

sub plugin_data_pre_save {
	my ($cb, $obj, $original) = @_;
	my $app = MT->instance;
	my $plugin = $app->component('GoogleDocs');

	return 1 unless $app->can('param');
	return 1 unless lc($app->param('plugin_sig')) eq $plugin->id;
	return 1 unless $app->param('enabled');

	my $email = $app->param('email');
	my $pass  = $app->param('password');
	if (! $email || ! $pass) {
		$cb->error($plugin->translate("Email and Password is required"));
		&show_error($cb);
	}

	if (my $base = $app->param('base_folder')) {
		my $id = GoogleDocs::Util::create_folder($cb, $base, $email, $pass)
			or &show_error($cb);
		my $data = $obj->data;
		$data->{'base_folder_id'} = $id;
		$obj->data($data);
	}

	return 1;
}

1;
