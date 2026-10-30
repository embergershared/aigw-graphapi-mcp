. (Join-Path $PSScriptRoot 'assert.ps1')
. (Join-Path $PSScriptRoot 'common.ps1')

$moduleRoot = Get-RepoPath 'infra/modules/api-management'
[xml]$policy = Get-Content (Join-Path $moduleRoot 'policies/rest.xml') -Raw
$requestExpression = $policy.SelectSingleNode('//set-variable[@name="validatedGraphUrl"]').value
$responseExpression = $policy.SelectSingleNode('//set-variable[@name="shapedGraphResponse"]').value
$requestBody = $requestExpression.Substring(2, $requestExpression.Length - 3)
$responseBody = $responseExpression.Substring(2, $responseExpression.Length - 3)
$errorExpression=$policy.SelectSingleNode('//on-error/return-response/set-body').InnerText
$errorBody=$errorExpression.Substring(2,$errorExpression.Length-3)
[xml]$oboPolicy = Get-Content (Join-Path $moduleRoot 'policies/obo.xml') -Raw
$oboBodies=@{}
foreach($name in @('oboFailureCode','oboStatus','oboRetryAfter','graphAccessToken')){
    $expression=$oboPolicy.SelectSingleNode("//set-variable[@name='$name']").value
    $oboBodies[$name]=$expression.Substring(2,$expression.Length-3)
}

# Compile the actual policy expressions, not a second implementation of their rules.
$source = @"
using System;
using System.Collections.Generic;
using System.Linq;
using Newtonsoft.Json.Linq;
namespace GraphPolicyTests {
  public sealed class Jwt { public Dictionary<string,string[]> Claims = new Dictionary<string,string[]>(); }
  public sealed class Operation { public string Id; }
  public sealed class Url { public Dictionary<string,string[]> Query = new Dictionary<string,string[]>(); }
  public sealed class Request {
    public string Method = "GET";
    public Url Url = new Url();
    public Dictionary<string,string> MatchedParameters = new Dictionary<string,string>();
  }
  public sealed class Body {
    public string Value = "{}";
    public T As<T>(bool preserveContent = false) {
      return typeof(T) == typeof(JObject) ? (T)(object)JObject.Parse(Value) : (T)(object)Value;
    }
  }
  public interface IResponse {
    int StatusCode { get; set; }
    Body Body { get; }
    Dictionary<string,string> Headers { get; }
  }
  public sealed class Response : IResponse {
    public int StatusCode { get; set; } = 200;
    public Body Body { get; } = new Body();
    public Dictionary<string,string> Headers { get; } = new Dictionary<string,string>();
  }
  public sealed class Context {
    public Operation Operation = new Operation();
    public Request Request = new Request();
    public Response Response = new Response();
    public Dictionary<string,object> Variables = new Dictionary<string,object>();
    public Failure LastError = new Failure();
    public void SetContract(string value) { Variables["graphContract"] = value; }
    public void SetObo(int status, string body, string retry) {
      var response = new Response { StatusCode = status };
      response.Body.Value = body;
      response.Headers["Retry-After"] = retry;
      Variables["oboResponse"] = response;
    }
    public void SetCode(string code) { Variables["oboFailureCode"] = code; }
  }
  public sealed class Failure { public string Source = ""; public string Reason = ""; public string PolicyId = ""; }
  public static class Expressions {
    public static string Request(Context context) { $requestBody }
    public static string Response(Context context) { $responseBody }
    public static string OboFailure(Context context) { $($oboBodies.oboFailureCode) }
    public static int OboStatus(Context context) { $($oboBodies.oboStatus) }
    public static int OboRetryAfter(Context context) { $($oboBodies.oboRetryAfter) }
    public static string OboToken(Context context) { $($oboBodies.graphAccessToken) }
    public static string Error(Context context) { $errorBody }
  }
}
"@
$references = @((Get-ChildItem (Join-Path $PSHOME 'ref') -Filter *.dll).FullName) + @([Newtonsoft.Json.Linq.JObject].Assembly.Location)
Add-Type -TypeDefinition $source -ReferencedAssemblies $references -CompilerOptions '/nowarn:1701','/langversion:7.3'
$contractJson = Get-Content (Join-Path $moduleRoot 'contract.json') -Raw
$syntheticUser = '00000000-0000-0000-0000-000000000001'

function New-PolicyContext([string]$Operation, [hashtable]$Query = @{}, [string]$Body = '{}') {
    $context = [GraphPolicyTests.Context]::new()
    $context.Operation.Id = $Operation
    $context.SetContract($contractJson)
    $jwt = [GraphPolicyTests.Jwt]::new()
    $jwt.Claims['oid'] = [string[]]@($syntheticUser)
    $context.Variables['gatewayJwt'] = $jwt
    foreach ($key in $Query.Keys) { $context.Request.Url.Query[$key] = [string[]]@($Query[$key]) }
    $context.Response.Body.Value = $Body
    return $context
}

function New-TestCursor([string]$Link, [string]$User = $syntheticUser, [string]$Operation = 'list_messages') {
    $json = @{operation=$Operation;userId=$User;nextLink=$Link} | ConvertTo-Json -Compress
    return [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json)).TrimEnd('=').Replace('+','-').Replace('/','_')
}

Test-Case 'actual policy defaults to ten and rejects invalid, duplicate and unknown arguments' {
    $uri = [GraphPolicyTests.Expressions]::Request((New-PolicyContext list_messages))
    Assert-Match $uri '\$top=10' 'Default must be ten.'
    foreach ($size in @('1','25')) {
        Assert-Match ([GraphPolicyTests.Expressions]::Request((New-PolicyContext list_messages @{page_size=$size}))) "\`$top=$size" 'Valid boundary rejected.'
    }
    foreach ($size in @('0','26','-1','1.5','garbage')) {
        Assert-Equal ([GraphPolicyTests.Expressions]::Request((New-PolicyContext list_messages @{page_size=$size}))) 'invalid_page_size' 'Reject, never clamp.'
    }
    Assert-Equal ([GraphPolicyTests.Expressions]::Request((New-PolicyContext list_messages @{'$select'='body'}))) 'unknown_or_duplicate_argument' 'No arbitrary OData.'
    Assert-Equal ([GraphPolicyTests.Expressions]::Request((New-PolicyContext list_messages @{page_size=@('1','2')}))) 'unknown_or_duplicate_argument' 'Reject duplicated parameters.'
}

Test-Case 'actual calendar policy checks offsets and the exact 31-day elapsed boundary' {
    $start = '2026-01-01T00:00:00Z'
    Assert-Match ([GraphPolicyTests.Expressions]::Request((New-PolicyContext list_calendar_view @{start=$start;end='2026-02-01T00:00:00Z'}))) '^https://' 'Exactly 31 days is valid.'
    Assert-Equal ([GraphPolicyTests.Expressions]::Request((New-PolicyContext list_calendar_view @{start=$start;end='2026-02-01T00:00:01Z'}))) 'invalid_calendar_window' 'A second beyond the cap must fail.'
    Assert-Equal ([GraphPolicyTests.Expressions]::Request((New-PolicyContext list_calendar_view @{start=$start;end=$start}))) 'invalid_calendar_window' 'End must be later.'
    Assert-Equal ([GraphPolicyTests.Expressions]::Request((New-PolicyContext list_calendar_view @{start='2026-01-01T00:00:00';end='2026-01-02T00:00:00Z'}))) 'calendar_offsets_required' 'No inferred time zone.'
    Assert-Match ([GraphPolicyTests.Expressions]::Request((New-PolicyContext list_calendar_view @{start='2026-01-01T00:00:00-05:00';end='2026-01-02T00:00:00-04:00'}))) '^https://' 'Explicit offsets are supported.'
    $culture=[Globalization.CultureInfo]::CurrentCulture
    try {
        [Globalization.CultureInfo]::CurrentCulture=[Globalization.CultureInfo]::GetCultureInfo('th-TH')
        Assert-Match ([GraphPolicyTests.Expressions]::Request((New-PolicyContext list_calendar_view @{start='2024-02-29T00:00:00Z';end='2024-03-01T00:00:00Z'}))) '^https://' 'ISO instants must not become local-calendar dates.'
    } finally { [Globalization.CultureInfo]::CurrentCulture=$culture }
}

Test-Case 'actual continuation policy rejects host/path/user/field/page escalation and mixing' {
    $initial = [GraphPolicyTests.Expressions]::Request((New-PolicyContext list_messages @{page_size='25'}))
    $link = $initial + '&$skip=50'
    $cursor = New-TestCursor $link
    Assert-Equal ([GraphPolicyTests.Expressions]::Request((New-PolicyContext list_messages @{continuation=$cursor}))) $link 'Preserve the exact service-issued paging query.'
    foreach ($invalid in @(
        $link.Replace('graph.microsoft.com','contoso.com'),
        $link.Replace('/me/messages','/users/another/messages'),
        $link.Replace('$top=25','$top=26'),
        $link.Replace('id%2Csubject','body%2Csubject'),
        ($link + '&$filter=anything')
    )) {
        Assert-Equal ([GraphPolicyTests.Expressions]::Request((New-PolicyContext list_messages @{continuation=(New-TestCursor $invalid)}))) 'invalid_continuation' 'Fail closed on forged continuations.'
    }
    Assert-Equal ([GraphPolicyTests.Expressions]::Request((New-PolicyContext list_messages @{continuation=(New-TestCursor $link '00000000-0000-0000-0000-000000000002')}))) 'invalid_continuation' 'A cursor from another user is invalid.'
    Assert-Equal ([GraphPolicyTests.Expressions]::Request((New-PolicyContext list_messages @{continuation=$cursor;page_size='10'}))) 'continuation_must_be_sent_alone' 'Never merge shaping parameters.'
    foreach ($invalid in @('e30','!')) {
        Assert-Equal ([GraphPolicyTests.Expressions]::Request((New-PolicyContext list_messages @{continuation=$invalid}))) 'invalid_continuation' 'Malformed cursors must be explicit input errors.'
    }
    foreach ($invalid in @('garbage','a')) {
        Assert-Throws {[GraphPolicyTests.Expressions]::Request((New-PolicyContext list_messages @{continuation=$invalid}))} 'Invalid base64/JSON must enter APIM on-error.'
    }
    $failure=New-PolicyContext list_messages
    $failure.LastError.PolicyId='graph-arguments'
    $problem=[GraphPolicyTests.Expressions]::Error($failure) | ConvertFrom-Json
    Assert-Equal $problem.status 400 'Actual on-error must turn cursor parse failures into input errors.'
    Assert-Equal $problem.code 'invalid_continuation' 'Never expose parser details.'
}

Test-Case 'actual detail policy enforces UTF-8 bytes at and above the boundary without truncation' {
    $prefix = '{"id":"synthetic","subject":"'
    $suffix = '"}'
    $raw = $prefix + ('x' * (65536 - $prefix.Length - $suffix.Length)) + $suffix
    Assert-Equal ([GraphPolicyTests.Expressions]::Response((New-PolicyContext get_message @{} $raw))) $raw 'Exactly 65536 bytes must survive unchanged.'
    Assert-Equal ([GraphPolicyTests.Expressions]::Response((New-PolicyContext get_message @{} ($raw.Replace('synthetic','syntheticx'))))) 'response_too_large' 'One extra byte must fail.'
    $multibyte = $prefix + ([string][char]0x00e9 * 33000) + $suffix
    Assert-Equal ([GraphPolicyTests.Expressions]::Response((New-PolicyContext get_message @{} $multibyte))) 'response_too_large' 'The limit is bytes, not UTF-16 string length.'
    Assert-Equal ([GraphPolicyTests.Expressions]::Response((New-PolicyContext get_message @{} '{"id":"synthetic","body":{"contentType":"html","content":"<script>untrusted</script>"}}'))) 'unsupported_body_format' 'Never return active HTML.'
}

Test-Case 'actual list policy strips unselected content and emits only a bounded user-bound cursor' {
    $raw = '{"value":[{"id":"synthetic","subject":"hello","body":{"content":"untrusted"}}]}'
    $result = [GraphPolicyTests.Expressions]::Response((New-PolicyContext list_messages @{} $raw)) | ConvertFrom-Json
    Assert-Equal $result.items.Count 1 'Keep all selected items.'
    Assert-True ($null -eq $result.items[0].PSObject.Properties['body']) 'List bodies must never leak.'
    Assert-True ($null -eq $result.continuation) 'No next link means finished, not a new page.'
    $items = @(1..26 | ForEach-Object { @{id="synthetic$_"} })
    $tooMany = @{value=$items} | ConvertTo-Json -Compress
    Assert-Equal ([GraphPolicyTests.Expressions]::Response((New-PolicyContext list_messages @{} $tooMany))) 'invalid_backend_response' 'Do not silently truncate an oversized page.'
    $prefix='{"items":[{"id":"synthetic","subject":"'
    $suffix='"}],"continuation":null}'
    $subject='x' * (131072-$prefix.Length-$suffix.Length)
    $raw='{"value":[{"id":"synthetic","subject":"' + $subject + '"}]}'
    $result=[GraphPolicyTests.Expressions]::Response((New-PolicyContext list_messages @{} $raw))
    Assert-Equal ([Text.Encoding]::UTF8.GetByteCount($result)) 131072 'Exactly the shaped list-byte boundary must survive.'
    $raw='{"value":[{"id":"synthetic","subject":"' + $subject + 'x"}]}'
    Assert-Equal ([GraphPolicyTests.Expressions]::Response((New-PolicyContext list_messages @{} $raw))) 'response_too_large' 'Shaping overhead counts toward the bound.'
}

Test-Case 'actual detail policy encodes one opaque ID and never accepts arbitrary paths or query arguments' {
    $context=New-PolicyContext get_message
    $context.Request.MatchedParameters['message_id']='A/+=='
    Assert-Match ([GraphPolicyTests.Expressions]::Request($context)) '/messages/A%2F%2B%3D%3D\?' 'Encode an ID as exactly one path segment.'
    $context.Request.MatchedParameters['message_id']='../users/other'
    Assert-Equal ([GraphPolicyTests.Expressions]::Request($context)) 'invalid_item_id' 'No traversal or user substitution.'
    $context=New-PolicyContext get_event @{page_size='1'}
    Assert-Equal ([GraphPolicyTests.Expressions]::Request($context)) 'unknown_or_duplicate_argument' 'Detail calls have no arbitrary shaping arguments.'
}

Test-Case 'actual OBO expressions distinguish consent from credential failures and bound throttle guidance' {
    $context=New-PolicyContext list_messages
    foreach($error in @('invalid_grant','interaction_required','consent_required','login_required')) {
        $context.SetObo(400, ('{"error":"' + $error + '"}'), '99999')
        $code=[GraphPolicyTests.Expressions]::OboFailure($context)
        Assert-Equal $code 'graph_user_action_required' 'Consent/CA must remain actionable.'
        $context.SetCode($code)
        Assert-Equal ([GraphPolicyTests.Expressions]::OboStatus($context)) 403 'User action is not an operator credential failure.'
    }
    foreach($error in @('invalid_client','unauthorized_client','invalid_scope')) {
        $context.SetObo(400, ('{"error":"' + $error + '"}'), '99999')
        $code=[GraphPolicyTests.Expressions]::OboFailure($context)
        Assert-Equal $code 'obo_configuration_error' 'Bad credentials are not solved by another consent.'
        $context.SetCode($code)
        Assert-Equal ([GraphPolicyTests.Expressions]::OboStatus($context)) 502 'Fail explicitly on middle-tier configuration errors.'
    }
    $context.SetObo(429,'{}','99999')
    Assert-Equal ([GraphPolicyTests.Expressions]::OboFailure($context)) 'obo_throttled' 'Explicit throttle.'
    Assert-Equal ([GraphPolicyTests.Expressions]::OboRetryAfter($context)) 30 'Never return unbounded Retry-After.'
    $context.SetObo(429,'{}','-1')
    Assert-Equal ([GraphPolicyTests.Expressions]::OboRetryAfter($context)) 1 'Minimum positive delay.'
    $context.SetObo(429,'{}','invalid')
    Assert-Equal ([GraphPolicyTests.Expressions]::OboRetryAfter($context)) 5 'Documented bounded fallback.'
}

Test-Case 'actual OBO token expression rejects absent, malformed, empty and oversized tokens' {
    $context=New-PolicyContext list_messages
    foreach($body in @('{}','{"access_token":"","token_type":"Bearer"}','{"access_token":"synthetic","token_type":"wrong"}')) {
        $context.SetObo(200,$body,'5')
        Assert-Equal ([GraphPolicyTests.Expressions]::OboToken($context)) '' 'An invalid exchange must not forward an empty Bearer token.'
    }
    $context.SetObo(200,'{"access_token":"synthetic-not-a-credential","token_type":"Bearer"}','5')
    Assert-Equal ([GraphPolicyTests.Expressions]::OboToken($context)) 'synthetic-not-a-credential' 'Only a valid-shaped token reaches backend authorization.'
    $context.SetObo(200,('{"access_token":"' + ('x'*16385) + '","token_type":"Bearer"}'),'5')
    Assert-Equal ([GraphPolicyTests.Expressions]::OboToken($context)) '' 'Bound the exchange token field.'
    $context.SetObo(200,'not json','5')
    Assert-Throws {[GraphPolicyTests.Expressions]::OboToken($context)} 'Malformed JSON must enter APIM on-error.'
    $context.LastError.PolicyId='obo-token'
    $problem=[GraphPolicyTests.Expressions]::Error($context) | ConvertFrom-Json
    Assert-Equal $problem.status 502 'Malformed exchange is an explicit backend failure.'
    Assert-Equal $problem.code 'obo_invalid_response' 'Never return the token endpoint body.'
}
