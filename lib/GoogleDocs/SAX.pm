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

package GoogleDocs::GData::Handler;

use strict;
use warnings;
use utf8;

use XML::SAX::Base;
use base qw(XML::SAX::Base);

sub new {
    my $class = shift;
    my (%param) = @_;
    my $self = bless \%param, $class;

	$self->{'_current_entry'} = undef;
	$self->{'_current_tag'} = '';

    return $self;
}

sub start_element {
	my $self = shift;
	my $data = shift;

	if ($data->{'Name'} eq 'entry') {
		$self->{'_current_entry'} = {};
	}

	if (grep($data->{'Name'} eq $_, 'title', 'id')) {
		$self->{'_current_tag'} = $data->{'Name'};
	}
	else {
		$self->{'_current_tag'} = '';
	}
}

sub characters {
	my $self = shift;
	my $data = shift;

	if ($self->{'_current_entry'} && $self->{'_current_tag'}) {
		$self->{'_current_entry'}{$self->{'_current_tag'}} ||= '';
		$self->{'_current_entry'}{$self->{'_current_tag'}} .= $data->{'Data'};
	}
}

sub end_element {
	my $self = shift;
	my $data = shift;

	if ($data->{'Name'} eq 'entry') {
		if (
			$self->{'folder_title'}
			&& $self->{'_current_entry'}{'title'} eq $self->{'folder_title'}
		) {
			$self->{'detected_folder'} = $self->{'_current_entry'};
		}
	}
}

package GoogleDocs::Search::GData::Handler;

use strict;
use warnings;
use utf8;

use XML::SAX::Base;
use base qw(XML::SAX::Base);

sub new {
    my $class = shift;
    my (%param) = @_;
    my $self = bless \%param, $class;

	$self->{'entries'} = [];
	$self->{'next'} = $self->{'previous'} = undef;
	$self->{'_current_entry'} = undef;
	$self->{'_current_tag'} = '';

    return $self;
}

sub start_element {
	my $self = shift;
	my $data = shift;

	if ($data->{'Name'} eq 'entry') {
 		$self->{'_current_entry'} = {};
		while (my ($k, $v) = each(%{ $data->{'Attributes'} })) {
			if ($k =~ m/etag$/) {
				$self->{'_current_entry'}{'etag'} = $v->{'Value'};
			}
		}
	}
	elsif ($data->{'Name'} eq 'link') {
		if ($data->{'Attributes'}{'{}rel'}) {
			foreach my $k ('next', 'previous') {
				if ($data->{'Attributes'}{'{}rel'}->{'Value'} eq $k) {
					$self->{$k} = {};
					my $v = $data->{'Attributes'}{'{}href'}->{'Value'};
					foreach my $p ('max-results', 'start-index', 'start-key') {
						if ($v =~ m/$p=([^\&]*)/) {
							$self->{$k}{$p} = $1;
						}
					}
				}
			}
		}
	}

	my @tags = qw(
		id openSearch:totalResults openSearch:startIndex
	);
	if (grep($data->{'Name'} eq $_, @tags)) {
		$self->{'_current_tag'} = $data->{'Name'};
	}
	else {
		$self->{'_current_tag'} = '';
	}
}

sub characters {
	my $self = shift;
	my $data = shift;

	if ($self->{'_current_tag'}) {
		if ($self->{'_current_entry'}) {
			$self->{'_current_entry'}{$self->{'_current_tag'}} ||= '';
			$self->{'_current_entry'}{$self->{'_current_tag'}} .= $data->{'Data'};
		}
		else {
			$self->{$self->{'_current_tag'}} ||= '';
			$self->{$self->{'_current_tag'}} .= $data->{'Data'};
		}
	}
}

sub end_element {
	my $self = shift;
	my $data = shift;

	if ($data->{'Name'} eq 'entry') {
		my $e = $self->{'_current_entry'};
		if ($e->{'id'} =~ m{%3A([^/]*)}) {
			$e->{'id'} = $1;
		}
		push(@{ $self->{'entries'} }, $e);
	}
}

1;
