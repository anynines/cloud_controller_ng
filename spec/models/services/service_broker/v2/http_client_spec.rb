require 'spec_helper'

module VCAP::CloudController
  describe ServiceBroker::V2::ServiceBrokerBadResponse do
    let(:endpoint) { 'http://www.example.com/' }
    let(:response_body) do
      { 'foo' => 'bar' }.to_json
    end
    let(:response) { double(code: 500, reason: 'Internal Server Error', body: response_body) }

    it 'generates the correct hash' do
      exception = described_class.new(endpoint, response)
      exception.set_backtrace(['/foo:1', '/bar:2'])

      expect(exception.to_h).to eq({
        'description' => "The service broker API returned an error from http://www.example.com/: 500 Internal Server Error",
        'error' => {
          'types' => ["VCAP::CloudController::ServiceBroker::V2::ServiceBrokerBadResponse", "HttpError", "StructuredError", "StandardError"],
          'backtrace' => ['/foo:1', '/bar:2'],
          'error' => { 'foo' => 'bar' }
        }
      })
    end
  end

  describe ServiceBroker::V2::HttpClient do
    let(:auth_token) { 'abc123' }
    let(:request_id) { Sham.guid }

    subject(:client) do
      ServiceBroker::V2::HttpClient.new(
        url: 'http://broker.example.com',
        auth_token: auth_token
      )
    end

    before do
      VCAP::Request.stub(:current_id).and_return(request_id)
    end

    describe '#catalog' do
      let(:service_id) { Sham.guid }
      let(:service_name) { Sham.name }
      let(:service_description) { Sham.description }
      let(:plan_id) { Sham.guid }
      let(:plan_name) { Sham.name }
      let(:plan_description) { Sham.description }
      let(:catalog_response) do
        {
          'services' => [
            {
              'id' => service_id,
              'name' => service_name,
              'description' => service_description,
              'plans' => [
                {
                  'id' => plan_id,
                  'name' => plan_name,
                  'description' => plan_description
                }
              ]
            }
          ]
        }
      end

      it 'fetches the broker catalog' do
        stub_request(:get, "http://cc:#{auth_token}@broker.example.com/v2/catalog").
          with(headers: { 'X-VCAP-Request-ID' => request_id }).
          to_return(body: catalog_response.to_json)

        catalog = client.catalog

        expect(catalog).to eq(catalog_response)
      end
    end

    describe '#provision' do
      let(:instance_id) { Sham.guid }
      let(:plan_id) { Sham.guid }

      let(:expected_request_body) do
        {
          plan_id: plan_id,
          organization_guid: "org-guid",
          space_guid: "space-guid"
        }.to_json
      end

      let(:expected_response_body) do
        {
          dashboard_url: 'dashboard url'
        }.to_json
      end

      it 'calls the provision endpoint' do
        stub_request(:put, "http://cc:#{auth_token}@broker.example.com/v2/service_instances/#{instance_id}").
          with(body: expected_request_body, headers: { 'X-VCAP-Request-ID' => request_id }).
          to_return(status: 201, body: expected_response_body)

        response = client.provision(instance_id, plan_id, "org-guid", "space-guid")

        expect(response.fetch('dashboard_url')).to eq('dashboard url')
      end

      context 'the reference_id is already in use' do
        it 'raises ServiceBrokerConflict' do
          stub_request(:put, "http://cc:#{auth_token}@broker.example.com/v2/service_instances/#{instance_id}").
            to_return(status: 409)  # 409 is CONFLICT

          expect { client.provision(instance_id, plan_id, "org-guid", "space-guid") }.to raise_error(VCAP::Errors::ServiceBrokerConflict)
        end
      end
    end

    describe '#bind' do
      let(:service_binding) { ServiceBinding.make }
      let(:service_instance) { service_binding.service_instance }

      let(:bind_url) { "http://cc:#{auth_token}@broker.example.com/v2/service_bindings/#{service_binding.guid}" }

      before do
        @request = stub_request(:put, bind_url).to_return(
          body: {
            credentials: {user: 'admin', pass: 'secret'}
          }.to_json
        )
      end

      it 'sends a PUT request to the correct endpoint with the auth token' do
        client.bind(service_binding.guid, service_instance.guid)

        expect(@request.with { |request|
          request_body = Yajl::Parser.parse(request.body)
          expect(request_body.fetch('service_instance_id')).to eq(service_binding.service_instance.guid)
        }).to have_been_made
      end

      it 'includes the request_id in the request header' do
        client.bind(service_binding.guid, service_instance.guid)

        expect(@request.with { |request|
          expect(request.headers.fetch('X-Vcap-Request-Id')).to eq(request_id)
        }).to have_been_made
      end

      it 'sets the content type to JSON' do
        client.bind(service_binding.guid, service_instance.guid)

        expect(@request.with { |request|
          expect(request.headers.fetch('Content-Type')).to eq('application/json')
        }).to have_been_made
      end

      it 'responds with the correct fields' do
        response = client.bind(service_binding.guid, service_instance.guid)

        expect(response.fetch('credentials')).to eq({'user' => 'admin', 'pass' => 'secret'})
      end
    end

    describe '#unbind' do
      let(:service_binding) { ServiceBinding.make }
      let(:bind_url) { "http://cc:#{auth_token}@broker.example.com/v2/service_bindings/#{service_binding.guid}" }
      before do
        @request = stub_request(:delete, bind_url).to_return(status: 204)
      end

      it 'sends a DELETE to the broker' do
        client.unbind(service_binding.guid)
        @request.should have_been_requested
      end
    end

    describe '#deprovision' do
      let(:instance) { ManagedServiceInstance.make }
      let(:instance_url) { "http://cc:#{auth_token}@broker.example.com/v2/service_instances/#{instance.guid}" }
      before do
        @request = stub_request(:delete, instance_url).to_return(status: 204)
      end

      it 'sends a DELETE to the broker' do
        client.deprovision(instance.guid)
        @request.should have_been_requested
      end
    end

    describe 'error conditions' do
      let(:broker_catalog_url) { "http://cc:#{auth_token}@broker.example.com/v2/catalog" }

      context 'when the API is not reachable' do
        context 'because the host could not be resolved' do
          before do
            stub_request(:get, broker_catalog_url).to_raise(SocketError)
          end

          it 'should raise an unreachable error' do
            expect {
              client.catalog
            }.to raise_error(VCAP::CloudController::Errors::ServiceBrokerApiUnreachable)
          end
        end

        context 'because the server connection attempt timed out' do
          before do
            stub_request(:get, broker_catalog_url).to_raise(HTTPClient::ConnectTimeoutError)
          end

          it 'should raise an unreachable error' do
            expect {
              client.catalog
            }.to raise_error(VCAP::CloudController::Errors::ServiceBrokerApiUnreachable)
          end
        end

        context 'because the server refused our connection' do
          before do
            stub_request(:get, broker_catalog_url).to_raise(Errno::ECONNREFUSED)
          end

          it 'should raise an unreachable error' do
            expect {
              client.catalog
            }.to raise_error(VCAP::CloudController::Errors::ServiceBrokerApiUnreachable)
          end
        end
      end

      context 'when the API times out' do
        context 'because the server gave up' do
          before do
            # We have to instantiate the error object to keep WebMock from initializing
            # it with a String message. KeepAliveDisconnected actually takes an optional
            # Session object, which later HTTPClient code attempts to use.
            stub_request(:get, broker_catalog_url).to_raise(HTTPClient::KeepAliveDisconnected.new)
          end

          it 'should raise a timeout error' do
            expect {
              client.catalog
            }.to raise_error(VCAP::CloudController::Errors::ServiceBrokerApiTimeout)
          end
        end

        context 'because the client gave up' do
          before do
            stub_request(:get, broker_catalog_url).to_raise(HTTPClient::ReceiveTimeoutError)
          end

          it 'should raise a timeout error' do
            expect {
              client.catalog
            }.to raise_error(VCAP::CloudController::Errors::ServiceBrokerApiTimeout)
          end
        end
      end

      context 'when the API returns an error code' do
        let(:error_response) { { 'foo' => 'bar' } }

        before do
          stub_request(:get, broker_catalog_url).to_return(
            status: [500, 'Internal Server Error'], body: error_response.to_json
          )
        end

        it 'should raise a ServiceBrokerBadResponse' do
          expect {
            client.catalog
          }.to raise_error { |e|
            expect(e).to be_a(VCAP::CloudController::ServiceBroker::V2::ServiceBrokerBadResponse)
            error_hash = e.to_h
            error_hash.fetch('description').should eq('The service broker API returned an error from http://broker.example.com/v2/catalog: 500 Internal Server Error')
            error_hash.fetch('error').should include({
              'types' => ['VCAP::CloudController::ServiceBroker::V2::ServiceBrokerBadResponse', 'HttpError', 'StructuredError', 'StandardError'],
              'error' => { 'foo' => 'bar' }
            })
          }
        end
      end

      context 'when the API returns an invalid response' do
        context 'because of an unexpected status code' do
          let(:catalog_response) { {'services' => []} }

          before do
            stub_request(:get, broker_catalog_url).to_return(
              status: [404, 'Not Found'], body: catalog_response.to_json
            )
          end

          it 'should raise an invalid response error' do
            expect {
              client.catalog
            }.to raise_error(
              VCAP::CloudController::ServiceBroker::V2::ServiceBrokerBadResponse,
              'The service broker API returned an error from http://broker.example.com/v2/catalog: 404 Not Found'
            )
          end
        end

        context 'because of an unexpected body' do
          before do
            stub_request(:get, broker_catalog_url).to_return(status: 200, body: '[]')
          end

          it 'should raise an invalid response error' do
            expect {
              client.catalog
            }.to raise_error(VCAP::CloudController::Errors::ServiceBrokerResponseMalformed)
          end
        end

        context 'because of an invalid JSON body' do
          before do
            stub_request(:get, broker_catalog_url).to_return(status: 200, body: 'invalid')
          end

          it 'should raise an invalid response error' do
            expect {
              client.catalog
            }.to raise_error(VCAP::CloudController::Errors::ServiceBrokerResponseMalformed)
          end
        end
      end

      context 'when the API cannot authenticate the client' do
        before do
          stub_request(:get, broker_catalog_url).to_return(status: 401)
        end

        it 'should raise an authentication error' do
          expect {
            client.catalog
          }.to raise_error(VCAP::CloudController::Errors::ServiceBrokerApiAuthenticationFailed)
        end
      end
    end
  end
end
