'use strict';

let co      = require('co');
let cli     = require('heroku-cli-util');
let format_date = require('../../lib/format_date.js');

let ssl_endpoints = require('../../lib/endpoints.js').endpoints;

function* run(context, heroku) {
  let certs = (yield ssl_endpoints(context.app, heroku)).all;

  if (certs.length === 0) {
    cli.log(`${context.app} has no SSL Endpoints.\nUse \`heroku _certs:add CRT KEY\` to add one.`);
  } else {
    let mapped = certs.filter(function(f) { return f.ssl_cert; }).map(function(f) {
      return {
        name:         f.name,
        cname:        f.cname,
        cert_domains: f.ssl_cert.cert_domains,
        expires_at:   f.ssl_cert.expires_at,
        ca_signed:    f.ssl_cert['ca_signed?'],
        type:         f._meta.type
      };
    });
    cli.table(mapped, {columns: [
      {label: 'Name', key: 'name'},
      {label: 'Endpoint', key: 'cname'},
      {label: 'Common Name(s)', key: 'cert_domains', format: function(f) { return f.join(', '); }},
      {label: 'Expires', key: 'expires_at', format: format_date},
      {label: 'Trusted', key: 'ca_signed', format: function(f) { return f ? 'True' : 'False'; }},
      {label: 'Type', key: 'type'}
    ]});
  }
}

module.exports = {
  topic: '_certs',
  description: 'List ssl endpoints for an app.',
  needsApp: true,
  needsAuth: true,
  run: cli.command(co.wrap(run)),
};
