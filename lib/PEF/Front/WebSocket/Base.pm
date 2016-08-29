package PEF::Front::WebSocket::Base;
use base 'PEF::Front::WebSocket::Interface';
use Protocol::WebSocket::Frame;
use Compress::Raw::Zlib 'Z_SYNC_FLUSH';
use warnings;
use strict;

sub close {
	my $self = $_[0];
	return if $self->{closed};
	my $handle = $self->{handle};
	$handle->on_drain;
	$handle->on_eof;
	$handle->on_read;
	if (not $self->{error} and not $self->{closed}) {
		$handle->push_write(
			Protocol::WebSocket::Frame->new(
				type    => 'close',
				version => $self->{handshake}->version
			)->to_bytes
		);
		$handle->push_shutdown;
	}
	$self->on_close if not $self->{closed};
	delete $self->{handle};
	$self->{closed} = 1;
}

sub is_defunct {
	my $self = $_[0];
	return $self->{error} || $self->{closed} || 0;
}

sub send {
	my ($self, $message, $type) = @_;
	return if $self->{closed} || $self->{error};
	$type ||= 'text';
	if ($type eq 'text') {
		utf8::encode($message);
	}
	$self->{expected_drain} = 1;
	my @rsv = ();
	if (   ($type eq 'text' || $type eq 'binary')
		&& length($message) >= PEF::Front::WebSocket::deflate_minimum_size()
		&& (my $deflate = $self->{deflate}))
	{
		$deflate->deflate(\$message, my $out);
		$deflate->flush($out, Z_SYNC_FLUSH);
		$message = substr($out, 0, -4);
		@rsv = (rsv => [1, 0, 0]);
	}
	$self->{handle}->push_write(
		Protocol::WebSocket::Frame->new(
			buffer           => $message,
			type             => $type,
			max_payload_size => length($message),
			version          => $self->{handshake}->version,
			@rsv
		)->to_bytes
	);
	return;
}

sub DESTROY {
	$_[0]->close;
}

1;
