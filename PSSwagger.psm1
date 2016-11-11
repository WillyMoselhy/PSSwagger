﻿$Global:parameters = @{}

<#
.DESCRIPTION
  Decodes the swagger spec and generates PowerShell cmdlets.

.PARAMETER  SwaggerSpecPath
  Full Path to a Swagger based JSON spec.

.PARAMETER  Path
  Full Path to a file where the commands are exported to.
#>
function Export-CommandFromSwagger
{
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, ParameterSetName = "PathParameterSet")]
        [String] $SwaggerSpecPath,

        [Parameter(Mandatory = $true, ParameterSetName = "URIParameterSet")]
        [Uri] $SwaggerSpecUri,

        [Parameter(Mandatory = $true)]
        [String] $Path,

        [Parameter(Mandatory = $true)]

        [String] $ModuleName
    )

    if ($PSCmdlet.ParameterSetName -eq 'PathParameterSet')
    {
        if (-not (Test-path $swaggerSpecPath))
        {
            throw "Swagger file $swaggerSpecPath does not exist. Check the path"
        }
    }
    elseif ($PSCmdlet.ParameterSetName -eq 'URIParameterSet')
    {
        $SwaggerSpecPath = [io.path]::GetTempFileName() + ".json"
        Write-Verbose "Swagger spec from $URI is downloaded to $SwaggerSpecPath"
        Invoke-WebRequest -Uri $SwaggerSpecUri -OutFile $SwaggerSpecPath
    }


    if ($path.EndsWith($moduleName))
    {
        throw "PATH does not need to end with ModuleName. ModuleName will be appended to the path"
    }

    $outputDirectory = join-path $path $moduleName
    if (Test-Path $outputDirectory)
    {
        throw "Directory $outputDirectory exists. Remove this directory and try again."
    }
    $null = New-Item -ItemType Directory $outputDirectory -ErrorAction Stop

    $namespace = "Microsoft.PowerShell.$moduleName"
    $Global:parameters.Add('namespace', $namespace)

    GenerateCsharpCode -swaggerSpecPath $swaggerSpecPath -path $outputDirectory -moduleName $moduleName -nameSpace $namespace
    GenerateModuleManifest -path $outputDirectory -moduleName $moduleName -rootModule "$moduleName.psm1"

    $modulePath = Join-Path $outputDirectory "$moduleName.psm1"

    $cmds = [System.Collections.ObjectModel.Collection[string]]::new()

    $jsonObject = ConvertFrom-Json ((Get-Content $swaggerSpecPath) -join [Environment]::NewLine) -ErrorAction Stop

    # Populate the global parameters
    $null = ProcessGlobalParams -globalParams $jsonObject.parameters -info $jsonObject.info
    $null = ProcessDefinitions -definitions $jsonObject.definitions

    # Handle the paths
    $jsonObject.Paths.PSObject.Properties | % {
        $jsonPathObject = $_.Value
        $jsonPathObject.psobject.Properties | % {
               $cmd = GenerateCommand $_.Value
               Write-Verbose $cmd
               $cmds.Add($cmd)
            } # jsonPathObject
    } # jsonObject

    $cmds | Out-File $modulePath -Encoding ASCII
}

#region Cmdlet Generation Helpers

<#
.DESCRIPTION
  Generates a cmdlet given a JSON custom object (from paths)
#>
function GenerateCommand([PSObject] $jsonPathItemObject)
{
$helpDescStr = @'
.DESCRIPTION
    $description
'@

$advFnSignature = @'
<#
$commandHelp
$paramHelp
#>
function $commandName
{
   [CmdletBinding()]
   param($paramblock
   )

   $body
}
'@

$parameterDefString = @'
    
    [Parameter(Mandatory = $isParamMandatory)]
    [$paramType] $paramName,
'@

$helpParamStr = @'

.PARAMETER $paramName
    $pDescription

'@

$functionBodyStr = @'
    $serviceCredentials = Get-AzCredentials
    $subscriptionId = Get-SubscriptionId

    $clientName = [$fullModuleName]::new($serviceCredentials, [System.Net.Http.DelegatingHandler[]]::new(0))
    $clientName.ApiVersion = $infoVersion
    $clientName.SubscriptionId = $subscriptionId
    $operationVar = $clientName.$operations.$methodName($requiredParamList)
'@

    $commandName = ProcessOperationId $jsonPathItemObject.operationId
    $description = $jsonPathItemObject.description
    $commandHelp = $executionContext.InvokeCommand.ExpandString($helpDescStr)

    [string]$paramHelp = ""
    $paramblock = ""
    $requiredParamList = ""
    $optionalParamList = ""
    $body = ""

    # Handle the function parameters
    #region Function Parameters

    $jsonPathItemObject.parameters | ForEach-Object {
        if($_.name)
        {
            $isParamMandatory = '$false'
            $paramName = '$' + $_.Name
            $paramType = if ($_.type) { $_.type } else { "object" }
            if ($_.required)
            { 
                $isParamMandatory = '$true'
                $requiredParamList += $paramName + ", "
            }
            else
            {
                $optionalParamList += $paramName + ", "
            }

            $paramblock += $executionContext.InvokeCommand.ExpandString($parameterDefString)
            if ($_.description)
            {
                $pDescription = $_.description
                $paramHelp += @"

.PARAMETER $($_.Name)
    $pDescription

"@
            }
        }
        elseif($_.'$ref')
        {
        }
    }# $parametersSpec

    $paramblock = $paramBlock.TrimEnd(",")
    $requiredParamList = $requiredParamList.TrimEnd(", ")
    $optionalParamList = $optionalParamList.TrimEnd(", ")

    #endregion Function Parameters

    # Handle the function body
    #region Function Body
    $infoVersion = $Global:parameters['infoVersion']
    $modulePostfix = $Global:parameters['infoTitle'] + '.'  + $Global:parameters['infoName']
    $fullModuleName = $Global:parameters['namespace'] + '.' + $modulePostfix
    $clientName = '$' + $modulePostfix.Split('.')[$_.count - 1]

    $operationName = $jsonPathItemObject.operationId.Split('_')[0]
    $operationType = $jsonPathItemObject.operationId.Split('_')[1]
    $operations = $operationName + 'Operations'
    $methodName = $operationType + 'WithHttpMessagesAsync'
    $operationVar = '$' + $operationName

    $serviceCredentials = '$' + 'serviceCredentials'
    $subscriptionId = '$' + 'subscriptionId'

    $body = $executionContext.InvokeCommand.ExpandString($functionBodyStr)

    #endregion Function Body

    $executionContext.InvokeCommand.ExpandString($advFnSignature)
}

<#
.DESCRIPTION
  Converts an operation id to a reasonably good cmdlet name
#>
function ProcessOperationId
{
    param([string] $opId)
    
    $cmdNounMap = @{"Create" = "New"; "Activate" = "Enable"; "Delete" = "Remove";
                    "List"   = "Get"}
    $opIdValues = $opId.Split('_')
    $cmdNoun = $opIdValues[0]
    $cmdVerb = $opIdValues[1]
    if (-not (get-verb $cmdVerb))
    {
        Write-Verbose "Verb $cmdVerb not an approved verb."
        if ($cmdNounMap.ContainsKey($cmdVerb))
        {
            Write-Verbose "Using Verb $($cmdNounMap[$cmdVerb]) in place of $cmdVerb."
            $cmdVerb = $cmdNounMap[$cmdVerb]
        }
        else
        {
            $idx=1
            for(; $idx -lt $opIdValues[1].Length; $idx++) { if (([int]$opIdValues[1][$idx] -ge 65) -and ([int]$opIdValues[1][$idx] -le 90)) {break;} }
            $cmdNoun = $cmdNoun + $opIdValues[1].Substring($idx)
            $cmdVerb = $opIdValues[1].Substring(0,$idx)
            if ($cmdNounMap.ContainsKey($cmdVerb)) { $cmdVerb = $cmdNounMap[$cmdVerb] }          

            Write-Verbose "Using Noun $cmdNoun. Using Verb $cmdVerb"
        }
    }
    return "$cmdVerb-$cmdNoun"
}

function ProcessGlobalParams
{
    param(
        [PSCustomObject] $globalParams,
        [PSCustomObject] $info
    )

    $globalParams.parameters.PSObject.Properties | % {
        $name = removeSpecialChars -strWithSpecialChars $_.name
        $Global:parameters.Add($name, $jsonObject.parameters.$name)
    }

    $infoVersion = $info.version
    $infoTitle = $info.title
    $infoName = $info.'x-ms-code-generation-settings'.name

    $Global:parameters.Add('infoVersion', $infoVersion)
    $Global:parameters.Add('infoTitle', $infoTitle)
    $Global:parameters.Add('infoName', $infoName)
}

function ProcessDefinitions
{
    param(
        [PSCustomObject] $definitions
    )
    
    $definitionList = @{}
    $definitions.PSObject.Properties | % {
        $name = $_.name
        $definitionList.Add($name, $_)
    }

    $Global:parameters.Add('definitionList', $definitionList)
}

function removeSpecialChars
{
    param([string] $strWithSpecialChars)

    $pattern = '[^a-zA-Z]'
    $resultStr = $strWithSpecialChars -replace $pattern, ''

    return $resultStr
}

#endregion