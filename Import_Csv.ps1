#1-Load the csv file
function Get-EmployeeCsv{
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory)]
        [string]$FilePath,
        [Parameter(Mandatory)]
        [string]$Delimiter,
        [Parameter(Mandatory)]
        [hashtable]$SyncFieldMap
    )

    try{
        $SyncProperties=$SyncFieldMap.GetEnumerator()
        $Properties=ForEach($Property in $SyncProperties){
            @{Name=$Property.Value;Expression=[scriptblock]::Create("`$_.$($Property.Key)")}
        }

        Import-Csv -Path $FilePath -Delimiter $Delimiter | Select-Object -Property $Properties

    } catch{
        Write-Error $_.Exception.Message
    }
}

#2-Load the employee already in AD
function Get-EmployeesFromAD{
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory)]
        [hashtable]$SyncFieldMap,
        [Parameter(Mandatory)]
        [string]$Domain,
        [Parameter(Mandatory)]
        [string]$UniqueId
    )

    try{
        Get-ADUser -Filter {$UniqueId -like "*"} -Server $Domain -Properties @($SyncFieldMap.Values)
    }catch{
        Write-Error -Message $_.Exception.Message
    }
}

#3-Compare the Users(AD and CSV File)
function Compare-Users{
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory)]
        [hashtable]$SyncFieldMap,
        [Parameter(Mandatory)]
        [string]$FilePath,
        [Parameter(Mandatory)]
        [string]$UniqueId,
        [Parameter(Mandatory)]
        [string]$Domain,
        [Parameter()]
        [string]$Delimiter=","
    )
    $CSVUsers=Get-EmployeeCsv -FilePath $FilePath -Delimiter $Delimiter -SyncFieldMap $SyncFieldMap
    $ADUsers=Get-EmployeesFromAD -SyncFieldMap $SyncFieldMap -UniqueId $UniqueId -Domain $Domain

    Compare-Object -ReferenceObject $ADUsers -DifferenceObject $CSVUsers -Property $UniqueId -IncludeEqual
}

#4-Get the new, synced and removed users in AD
function Get-UserSyncData{
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory)]
        [hashtable]$SyncFieldMap,
        [Parameter(Mandatory)]
        [string]$FilePath,
        [Parameter(Mandatory)]
        [string]$UniqueId,
        [Parameter(Mandatory)]
        [string]$Domain,
        [Parameter(Mandatory)]
        [string]$OUProperty,
        [Parameter()]
        [string]$Delimiter=","
    )
    try{
        $CompareData=Compare-Users -SyncFieldMap $SyncFieldMap -FilePath $FilePath -UniqueId $UniqueId -Delimiter $Delimiter -Domain $Domain
        $NewUsersID=$CompareData | where SideIndicator -eq "=>"
        $SyncedUsersID=$CompareData | where SideIndicator -eq "=="
        $RemovedUsersID=$CompareData | where SideIndicator -eq "<="

        $NewUsers=Get-EmployeeCsv -FilePath $FilePath -Delimiter $Delimiter -SyncFieldMap $SyncFieldMap | where $UniqueId -In $NewUsersID.$UniqueId
        $SyncedUsers=Get-EmployeeCsv -FilePath $FilePath -Delimiter $Delimiter -SyncFieldMap $SyncFieldMap | where $UniqueId -In $SyncedUsersID.$UniqueId
        $RemovedUsers=Get-EmployeesFromAD -SyncFieldMap $SyncFieldMap -Domain $Domain -UniqueId $UniqueId | where $UniqueId -In $RemovedUsersID.$UniqueId

        @{
            New=$NewUsers
            Synced=$SyncedUsers
            Removed=$RemovedUsers
            Domain=$Domain
            UniqueId=$UniqueId
            OUProperty=$OUProperty
        }
    }catch{
        Write-Error -Message $_.Exception.Message
    }
}

#5-Creating OU if not found so that Users get inserted according to OU(region)
function Validate-OU{
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory)]
        [hashtable]$SyncFieldMap,
        [Parameter(Mandatory)]
        [string]$FilePath,
        [Parameter(Mandatory)]
        [string]$OUProperty,
        [Parameter(Mandatory)]
        [string]$Domain,
        [Parameter()]
        [string]$Delimiter=","
    )
    try{
        $OUNames=Get-EmployeeCsv -FilePath $FilePath -Delimiter $Delimiter -SyncFieldMap $SyncFieldMap | select -Unique -Property $OUProperty
        foreach($OUName in $OUNames){
            $OUName=$OUName.$OUProperty
            if(-not (Get-ADOrganizationalUnit -Filter "name -eq '$OUName'" -Server $Domain)){
                New-ADOrganizationalUnit -Name $OUName -Server $Domain -ProtectedFromAccidentalDeletion $false
            }
        }
    }catch{
        Write-Error -Message $_.Exception.Message
    }
}

#6-a-Getting a new unique Username before creating users in AD
function New-UserName{
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory)]
        [string]$GivenName,
        [Parameter(Mandatory)]
        [string]$SurName,
        [Parameter(Mandatory)]
        [string]$Domain
    )
    [RegEx]$Pattern="\s|-|_"    #Regression Expression to detect mentioned expression in a String(Username)
    $index=1
    do{
        $UserName="$SurName$($GivenName.Substring(0,$index))" -replace $Pattern, ""
        $index++
    }while((Get-ADUser -Filter "samAccountName -like '$Username'") -and ($Username -notlike "$SurName$GivenName"))

    if(Get-ADUser -Filter "samAccountName -like '$Username'"){
        throw "No user available!!"
    }else{
        $Username
    }
}

#7-b-Creating User in AD
function Create-NewUsers{
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory)]
        [hashtable]$UserSyncData
    )
    
    try{
        $NewUsers=$UserSyncData.New
        # Creating newUsers using UserSyncData
        foreach($NewUser in $NewUsers){
            Write-Verbose "Creating user: {$($NewUser.givenname) $($NewUser.surname)}"
            $UserName=New-UserName -GivenName $NewUser.givenname -SurName $NewUser.surname -Domain $UserSyncData
            Write-Verbose "Creating User: {$($NewUser.givenname) $($NewUser.surname)} with Username: {$UserName}"
            if(-not ($OU=Get-ADOrganizationalUnit -Filter "name -eq '$($NewUser.$($UserSyncData.OUProperty))'" -Server $Domain)){
                throw "The oraganizationalUnit is '$($NewUser.$($UserSyncData.OUProperty))'"
            }
            Write-Verbose "Creating User: {$($NewUser.givenname) $($NewUser.surname)} with Username: {$UserName} in $OU"
        # Generate a random password
            Add-Type -AssemblyName 'System.Web'
            $Password=[System.Web.Security.MemberShip]::GeneratePassword((Get-Random -Minimum 15 -Maximum 18), 3)
            $SecurePassword=ConvertTo-SecureString -String $Password -AsPlainText -Force
        # Mapping for AD Users in AD
            $NewADUserParams=@{
                EmployeeID=$NewUser.EmployeeID
                GivenName=$NewUser.GivenName
                SurName=$NewUser.Surname
                Name=$Username
                samAccountName=$Username
                userPrincipalName="$Username@$($UserSyncData.Domain)"
                AccountPassword=$SecurePassword
                ChangePasswordAtLogon=$true
                Enable=$true
                Title=$NewUser.Title
                Office=$NewUser.Office
                Path=$OU.DistinguishedName
                Confirm=$false
                Server=$UserSyncData.Domain
            }
            New-ADUser @NewADUserParams
            Write-Verbose "Created User: {$($NewUser.givenName) $($NewUser.surname)} EmpId: $($NewUser.EmployeeID)"
        }
    }catch{
        Write-Error -Message $_.Exception.Message
    }
}

# Created the variable Mapping(Configuration)
$SyncFieldMap=@{
    EmployeeID="EmployeeID"
    FirstName="GivenName"
    LastName="Surname"
    Title="Title"
    Office="Company"
}

$UniqueId="EmployeeID"
$FilePath="C:\EmployeeData.txt"
$Delimiter=","
$Domain="luffy.local"
$OUProperty="Company"

# Get the NewUsers, SyncedUsers and RemovedUsers
$UserSyncData=Get-UserSyncData -SyncFieldMap $SyncFieldMap -FilePath $FilePath -UniqueId $UniqueId -Domain $Domain -Delimiter $Delimiter -OUProperty $OUProperty
# Cmd for creating OU
Validate-OU -SyncFieldMap $SyncFieldMap -FilePath $FilePath -OUProperty $OUProperty -Domain $Domain -Delimiter $Delimiter
# Cmd to create New users
Create-NewUsers -UserSyncData $UserSyncData -Verbose
