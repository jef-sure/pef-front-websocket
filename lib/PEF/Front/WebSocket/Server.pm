package PEF::Front::WebSocket::Server::Queue;
use strict;
use warnings;
use AnyEvent;
use Scalar::Util 'weaken';

sub new {
	bless {
		queue   => [],
		clients => {},
		id      => $_[1],
		server  => $_[2],
	};
}

sub add_client {
	my ($self, $client, $last_id) = @_;
	$self->{clients}{$client} = $client;
	if (defined $last_id) {
		if (@{$self->{queue}}) {
			if ($self->{queue}[0][0] <= $last_id) {
# если первое сообщение в очереди имеет айди не выше последнего,
# то у клиента есть как минимум часть актуальной очереди и никаких сообщений не было потеряно
# дошлём клиенту новые сообщения, если они появились
				for my $mt (@{$self->{queue}}) {
					my $id_message = $mt->[0];
					if ($id_message > $last_id) {
						$self->{server}->_send($id_message, $mt->[1], $client->group, [$client->id]);
					}
				}
			} else {
# если айди последнего сообщения клиента "безнадёжно устарел", то ему надо сообщить о необходимости
# перегрузить модель данных
				$self->{server}->_send(0, $self->{server}->reload_message, $client->group, [$client->id]);
			}
		} else {
# если в очереди нет сообщений, значит всё давно заэкспайрилось, клиенту надо перегрузить модель данных
			$self->{server}->_send(0, $self->{server}->reload_message, $client->group, [$client->id]);
		}
	}
# если клиент не показал "последенго айди", то у него только что загруженная модель данных
}

sub publish {
	my ($self, $id_message, $message) = @_;
	push @{$self->{queue}}, [$id_message, $message, time];
	my %g;
	for (keys %{$self->{clients}}) {
		my $c = $self->{clients}{$_};
		push @{$g{$c->group}}, $c->id;
	}
	for my $group (keys %g) {
		$self->{server}->_send($id_message, $message, $group, $g{$group});
	}
}

sub remove_client {
	my ($self, $client) = @_;
	delete $self->{clients}{$client};
	if (!%{$self->{clients}}) {
		weaken $self;
		$self->{destroy_timer} = AnyEvent->timer(
			after => $self->{server}->no_client_expiration,
			cb    => sub {
				if ($self && !%{$self->{clients}}) {
					$self->{server}->_remove_queue($self->{id});
					undef $self;
				}
			}
		);
	}
}

package PEF::Front::WebSocket::Server::Client;
use strict;
use warnings;

sub new {
	bless {
		group  => $_[1],
		id     => $_[2],
		queues => []
	};
}

sub group {
	$_[0]{group};
}

sub id {
	$_[0]{id};
}

sub subscribe {
	my ($self, $queue) = @_;
	$queue->add_client($self);
}

sub unsubscribe {
	my ($self, $queue) = @_;
	$queue->remove_client($self);
}

sub DESTROY {
	$_[0]->unsubscribe($_) for @{$_[0]{queues}};
}

package PEF::Front::WebSocket::Server;
use strict;
use warnings;

use Carp;
use Scalar::Util 'weaken';

use AnyEvent;
use AnyEvent::Handle;
use AnyEvent::Socket;
use CBOR::XS;

sub create_group {
	my ($self, $group) = @_;
	$self->{groups}{$group} = {};
}

sub destroy_group {
	my ($self, $group) = @_;
	delete $self->{groups}{$group};
}

sub on_cmd {
	my ($self, $handle, $scalar) = @_;
	my $group = $handle->fh->fileno;
	$handle->push_read(
		cbor => sub {
			$self->on_cmd(@_);
		}
	);
}

sub register_queue {
	my ($self, $queue) = @_;
	$self->{queues}{$queue} = PEF::Front::WebSocket::Server::Queue->new($queue, $self);
}

sub _remove_queue {
	my ($self, $queue) = @_;
	delete $self->{queues}{$queue};
}

sub on_disconnect {
	my ($self, $handle, $fatal, $msg) = @_;
	$self->destroy_group($handle->fh->fileno);
	$handle->destroy;

}

sub on_accept {
	my ($self, $fh, $host, $port) = @_;
	my $handle = AnyEvent::Handle->new(
		on_error => sub {$self->on_disconnect(@_)},
		on_eof   => sub {$self->on_disconnect(@_)},
		fh       => $fh,
	);
	$self->create_group($fh->fileno);
	$handle->unshift_read(
		cbor => sub {
			$self->on_cmd(@_);
		}
	);
}

sub new {
	my ($class, %args) = @_;
	my $self;
	my $tcp_address          = delete $args{address}              || '127.0.0.1';
	my $tcp_port             = delete $args{port}                 || 54321;
	my $no_client_expiration = delete $args{no_client_expiration} || 900;
	my $message_expiration   = delete $args{message_expiration}   || 3600;
	my $reload_message       = delete $args{reload_message}       || {result => 'RELOAD'};
	$self = {
		server               => tcp_server($tcp_address, $tcp_port, sub {$self->on_accept(@_)}),
		no_client_expiration => $no_client_expiration,
		message_expiration   => $message_expiration,
		reload_message       => $reload_message,
		groups               => {},
		queues               => {}
	};
	bless $self, $class;
}

sub no_client_expiration {
	$_[0]{no_client_expiration};
}

sub message_expiration {
	$_[0]{message_expiration};
}

sub reload_message {
	$_[0]{reload_message};
}

__END__

=head1 NAME


=head1 SYNOPSIS


=head1 DESCRIPTION



=head1 METHOD

=head1 new (@options)

Available C<%options> are:

=over 4

=item port => 'Int | Str'

Listening port or path to unix socket (Required)

=item address => 'Str'

Bind address. Default to undef: This means server binds all interfaces by default.

If you want to use unix socket, this option should be set to "unix/"

=item on_error => $cb->($handle, $fatal, $message)

Error callback which is called when some errors occured.
This is actually L<AnyEvent::Handle>'s on_error.

=item on_eof => $cb->($handle)

EOF callback. same as L<AnyEvent::Handle>'s on_eof callback.

=item on_accept => $cb->($fh, $host, $port)

=item on_dispatch => $cb->($indicator, $handle, $request);

=item handler_options => 'HashRef'

Hashref options of L<AnyEvent::Handle> that is used to handle client connections.

=back

=head2 reg_cb (%callbacks)

=head3 callback arguments

MessagePack RPC callback arguments consists of C<$result_cv>, and request C<@params>.

    my ($result_cv, @params) = @_;

C<$result_cv> is L<AnyEvent::MPRPC::CondVar> object.
Callback must be call C<<$result_cv->result>> to return result or C<<$result_cv->error>> to return error.

If C<$result_cv> is not defined, it is notify request, so you don't have to return response. See L<AnyEvent::MPRPC::Client> notify method.

C<@params> is same as request parameter.

=head1 AUTHOR


=head1 COPYRIGHT AND LICENSE

Copyright (c) 2016 by .

This program is free software; you can redistribute
it and/or modify it under the same terms as Perl itself.

The full text of the license can be found in the
LICENSE file included with this module.

=cut

